// Go Live on Linux. xdg-desktop-portal's ScreenCast (over libdbus) lets the desktop's own dialog pick the
// screen or window and hands over a PipeWire node; libpipewire streams it as 32-bit RGB, converted to NV12
// here. Soundshare captures every other app's playback through PipeWire (fastcord's own is left out),
// mixed to mono 48 kHz. Both libraries are opened with dlopen when sharing starts, so fastcord runs
// without them.

screen_supported :: () -> bool { return true; }
screen_targets_refresh :: () {}

// The portal's dialog chooses what to share, so the picker offers one tile. Its size is only known once
// the stream starts (0).
screen_targets :: () -> []Screen_Target, ready: bool {
	T :: Screen_Target.[.{id = 1, name = "Screen or window"}];
	return T, true;
}

screen_start :: (target: Screen_Target, on_frame: Frame_Proc, user: *void, fps := 30, max_height := 1080, on_audio: Audio_Proc = null) -> *Capture {
	c := New(Capture);
	c.* = .{on_frame = on_frame, on_audio = on_audio, user = user, height = max(max_height, 2), fps = max(fps, 1), target = target};
	c.target.name = "";
	start(c, screen_thread);
	return c;
}

#scope_module

// 24- or 32-bit RGB (r, g, b: each channel's byte in a pixel of bpp bytes) -> NV12 of w x h, fitted with black bars, with the
// matrix the receiving side assumes (BT.709 from 720 lines up). Shrinking averages 2x2 source pixels.
nv12_from_rgb :: (src: *u8, sw: int, sh: int, stride: int, bpp: int, r: int, g: int, b: int, w: int, h: int) -> *yuv.Nv12 {
	f := yuv.nv12_create(w, h);
	w, h = f.width, f.height;
	uv := f.data.data + w * h;
	fw, fh := w, h;
	if sw * h > sh * w fh = clamp(sh * w / sw, 2, h) & ~1;
	else fw = clamp(sw * h / sh, 2, w) & ~1;
	ox, oy := ((w - fw) / 2) & ~1, ((h - fh) / 2) & ~1;
	if fw != w || fh != h { memset(f.data.data, 16, w * h); memset(uv, 128, w * h / 2); }
	xs := NewArray(fw, int,, temp);
	for x: 0..fw - 1 xs[x] = (x * sw / fw) * bpp;
	dx := ifx sw > fw then bpp else 0; // the neighbour averaged in, while shrinking
	dy := ifx sh > fh then stride else 0;
	hd := h >= 720;
	for y: 0..fh - 1 {
		sy := y * sh / fh;
		row := src + sy * stride;
		ddy := ifx sy + 1 < sh then dy else 0;
		dst := f.data.data + (oy + y) * w + ox;
		d := uv + ((oy + y) / 2) * w + ox;
		for x: 0..fw - 1 {
			p := row + xs[x];
			ddx := ifx xs[x] + bpp < sw * bpp then dx else 0;
			q := p + ddy;
			R := (cast(s32) p[r] + p[r + ddx] + q[r] + q[r + ddx] + 2) >> 2;
			G := (cast(s32) p[g] + p[g + ddx] + q[g] + q[g + ddx] + 2) >> 2;
			B := (cast(s32) p[b] + p[b + ddx] + q[b] + q[b + ddx] + 2) >> 2;
			dst[x] = cast,trunc(u8) (ifx hd then ((47 * R + 157 * G + 16 * B + 128) >> 8) + 16 else ((66 * R + 129 * G + 25 * B + 128) >> 8) + 16);
			if (x | y) & 1 continue;
			cb := ifx hd then ((-26 * R - 86 * G + 112 * B + 128) >> 8) + 128 else ((-38 * R - 74 * G + 112 * B + 128) >> 8) + 128;
			cr := ifx hd then ((112 * R - 102 * G - 10 * B + 128) >> 8) + 128 else ((112 * R - 94 * G - 18 * B + 128) >> 8) + 128;
			d[x] = cast,trunc(u8) cb;
			d[x + 1] = cast,trunc(u8) cr;
		}
	}
	return f;
}

#scope_file

// ---- The capture thread: the portal, then the PipeWire streams until capture_stop or the session ends.

REPEAT_MS :: 500; // a still screen sends no frames: repeat the last one this often, so keyframes keep coming

screen_thread :: (t: *Thread) -> s64 {
	c := cast(*Capture) t.data;
	p: Portal;
	defer portal_close(*p);
	fd, node := portal_open(*p, c);
	if fd < 0 return 0;
	if !pw_load() { close(fd); c.error = "Screen sharing needs PipeWire."; return 0; }

	s := New(Screen);
	defer free(s);
	s.c = c;
	SIZE :: 1024 * 1024;
	s.ts.data = alloc(SIZE);
	s.ts.size = SIZE;
	defer free(s.ts.data);
	s.ctx = context;
	s.ctx.temporary_storage = *s.ts;
	s.ctx.stack_trace = null; // this thread's stack: the loop's thread must not write into it
	s.pid = getpid();
	comm := read_entire_file("/proc/self/comm", log_errors = false);
	if comm s.self_tag = sprint("[%]", trim(comm));
	free(comm);
	defer { yuv.nv12_release(s.last); array_free(s.own_clients); free(s.self_tag); }

	P.init(null, null);
	loop := P.thread_loop_new("fastcord-screen", null);
	if !loop { close(fd); c.error = "Couldn't start PipeWire."; return 0; }
	pctx := P.context_new(P.thread_loop_get_loop(loop), null, 0);
	if !pctx || P.thread_loop_start(loop) < 0 { close(fd); P.thread_loop_destroy(loop); c.error = "Couldn't start PipeWire."; return 0; }
	P.thread_loop_lock(loop);
	s.core = P.context_connect_fd(pctx, fd, null, 0); // takes the fd
	if s.core {
		s.video = P.stream_new(s.core, "fastcord screen", P.properties_new_string("media.type=Video media.category=Capture media.role=Screen"));
		if s.video {
			P.stream_add_listener(s.video, *s.video_hook, *VIDEO_EVENTS, s);
			pod: Pod;
			video_format(*pod, c.fps);
			param := pod.buf.data;
			if P.stream_connect(s.video, 0 /*INPUT*/, node, FLAG_AUTOCONNECT | FLAG_MAP_BUFFERS, *param, 1) < 0 atomic_store(*s.ended, true);
		}
	}
	// Soundshare: a connection of our own, since the portal's sees only the shared screen.
	if c.on_audio {
		s.audio_core = P.context_connect(pctx, null, 0);
		if s.audio_core {
			get_registry := cast(#type (obj: *void, version: u32, user_size: u64) -> *void #c_call) method(s.audio_core, 48);
			s.registry = get_registry(iface_data(s.audio_core), 3, 0);
			if s.registry {
				add_listener := cast(#type (obj: *void, hook: *Spa_Hook, events: *void, data: *void) -> s32 #c_call) method(s.registry, 8);
				add_listener(iface_data(s.registry), *s.registry_hook, *REGISTRY_EVENTS, s);
			}
		}
	}
	P.thread_loop_unlock(loop);
	if !s.core || !s.video c.error = "Couldn't start the screen stream.";

	while s.core && s.video && !atomic_load(*c.quit) && !atomic_load(*s.ended) && !p.closed {
		portal_poll(*p, 50);
		now := to_milliseconds(current_time_monotonic());
		locks.lock(*s.last_mu);
		f: *yuv.Nv12;
		if s.last && now - s.last_ms >= REPEAT_MS { f = yuv.nv12_retain(s.last); s.last_ms = now; }
		locks.unlock(*s.last_mu);
		if f { emit(c, f); yuv.nv12_release(f); }
	}
	if atomic_load(*s.failed) c.error = "The screen stream stopped.";

	P.thread_loop_lock(loop);
	for s.apps { P.stream_destroy(it.stream); free(it); }
	array_free(s.apps);
	if s.registry P.proxy_destroy(s.registry);
	if s.video P.stream_destroy(s.video);
	if s.audio_core P.core_disconnect(s.audio_core);
	if s.core P.core_disconnect(s.core);
	P.thread_loop_unlock(loop);
	P.thread_loop_stop(loop);
	P.context_destroy(pctx);
	P.thread_loop_destroy(loop);
	return 0;
}

Screen :: struct {
	c: *Capture;
	ctx: #Context; // for callbacks on the loop's thread, with its own temp
	ts: Temporary_Storage;
	core, audio_core, video, registry: *void;
	video_hook, registry_hook: Spa_Hook;
	ended, failed: bool; // atomic: the video stream went away or broke
	src_w, src_h: int;
	bpp, r, g, b: int; // the negotiated format's bytes a pixel and channel bytes
	shown_ms: s64; // loop thread: the last frame sent
	last_mu: locks.Mutex;
	last: *yuv.Nv12;
	last_ms: s64;
	// soundshare, on the loop's thread
	pid: s32;
	own_clients: [..]u32; // our own PipeWire clients, whose playback is left out
	self_tag: string; // "[fastcord]", how ALSA's PipeWire and Pulse plugins name our playback
	apps: [..]*App_Audio;
	mix: [MIX]float32; // ring, indexed by absolute sample % MIX
	out_pos: s64; // samples handed to on_audio
}

App_Audio :: struct {
	s: *Screen;
	node: u32;
	stream: *void;
	hook: Spa_Hook;
	pos: s64; // the next sample's absolute position in the mix
}

on_video_state :: (data: *void, old: s32, state: s32, error: *u8) #c_call {
	s := cast(*Screen) data;
	if state == STATE_ERROR atomic_store(*s.failed, true);
	if state == STATE_ERROR || (state == STATE_UNCONNECTED && old != STATE_UNCONNECTED) atomic_store(*s.ended, true);
}

on_video_param :: (data: *void, id: u32, param: *u8) #c_call {
	s := cast(*Screen) data;
	push_context s.ctx {
		if id != PARAM_FORMAT || !param return;
		f := parse_format(param);
		if f.media != MEDIA_VIDEO || f.w <= 0 || f.h <= 0 || f.w > 16384 || f.h > 16384 return;
		if f.format == {
			case FMT_BGRx; #through; case FMT_BGRA; s.bpp, s.r, s.g, s.b = 4, 2, 1, 0;
			case FMT_RGBx; #through; case FMT_RGBA; s.bpp, s.r, s.g, s.b = 4, 0, 1, 2;
			case FMT_xRGB; s.bpp, s.r, s.g, s.b = 4, 1, 2, 3;
			case FMT_xBGR; s.bpp, s.r, s.g, s.b = 4, 3, 2, 1;
			case FMT_RGB; s.bpp, s.r, s.g, s.b = 3, 0, 1, 2;
			case FMT_BGR; s.bpp, s.r, s.g, s.b = 3, 2, 1, 0;
			case; s.src_w = 0; return;
		}
		s.src_w, s.src_h = f.w, f.h;
		c := s.c;
		if !c.width { // the output's size, kept when the source resizes (a window)
			h := min(f.h, c.height);
			c.width, c.height = max(f.w * h / f.h, 2) & ~1, max(h, 2) & ~1;
		}
		pod: Pod;
		buffers_param(*pod);
		p := pod.buf.data;
		P.stream_update_params(s.video, *p, 1);
		reset_temporary_storage();
	}
}

on_video_process :: (data: *void) #c_call {
	s := cast(*Screen) data;
	push_context s.ctx {
		// only the newest buffer counts
		b: *Pw_Buffer;
		while true {
			n := P.stream_dequeue_buffer(s.video);
			if !n break;
			if b P.stream_queue_buffer(s.video, b);
			b = n;
		}
		if !b return;
		defer P.stream_queue_buffer(s.video, b);
		c := s.c;
		now := to_milliseconds(current_time_monotonic());
		if !s.src_w || now - s.shown_ms < 1000 / c.fps - 3 return;
		sb := b.buffer;
		if !sb || sb.n_datas < 1 || !sb.datas return;
		d := sb.datas;
		ch := d.chunk;
		if !d.data || !ch || (ch.flags & CHUNK_CORRUPTED) return;
		w, h := s.src_w, s.src_h;
		stride := ifx ch.stride > 0 then cast(int) ch.stride else w * s.bpp;
		if stride < w * s.bpp || cast(s64) ch.offset + stride * h > d.maxsize return;
		f := nv12_from_rgb(cast(*u8) d.data + ch.offset, w, h, stride, s.bpp, s.r, s.g, s.b, c.width, c.height);
		s.shown_ms = now;
		locks.lock(*s.last_mu);
		yuv.nv12_release(s.last);
		s.last, s.last_ms = yuv.nv12_retain(f), now;
		locks.unlock(*s.last_mu);
		emit(c, f); // resets temp
		yuv.nv12_release(f);
	}
}

VIDEO_EVENTS := Pw_Stream_Events.{version = 2, state_changed = on_video_state, param_changed = on_video_param, process = on_video_process};

// ---- Soundshare: one capture stream per app that plays (a Stream/Output/Audio node), downmixed and summed
// into a ring.

MIX :: 48000 / 4;
LAG :: 1920; // samples an app that stopped delivering may hold the mix back

on_global :: (data: *void, id: u32, permissions: u32, type: *u8, version: u32, props: *Spa_Dict) #c_call {
	s := cast(*Screen) data;
	push_context s.ctx {
		defer reset_temporary_storage();
		if !type || !props return;
		kind := cstr(type);
		if kind == "PipeWire:Interface:Client" {
			pid := dict(props, "pipewire.sec.pid");
			if !pid pid = dict(props, "application.process.id");
			n, ok := string_to_int(pid);
			if ok && n == s.pid array_add(*s.own_clients, id);
			return;
		}
		if kind != "PipeWire:Interface:Node" || dict(props, "media.class") != "Stream/Output/Audio" return;
		client, ok := string_to_int(dict(props, "client.id"));
		if ok for s.own_clients if it == cast(u32) client return;
		if s.self_tag && ends_with(dict(props, "application.name"), s.self_tag) return; // via pipewire-pulse, its client
		serial, sok := string_to_int(dict(props, "object.serial"));
		if !sok || serial < 0 || s.apps.count >= 64 return;
		a := New(App_Audio);
		a.* = .{s = s, node = id, pos = s.out_pos};
		a.stream = P.stream_new(s.audio_core, "fastcord soundshare", P.properties_new_string(temp_c_string(tprint("media.type=Audio media.category=Capture media.role=Screen node.dont-reconnect=true target.object=%", serial))));
		if !a.stream { free(a); return; }
		P.stream_add_listener(a.stream, *a.hook, *AUDIO_EVENTS, a);
		pod: Pod;
		audio_format(*pod);
		param := pod.buf.data;
		if P.stream_connect(a.stream, 0 /*INPUT*/, ANY_ID, FLAG_AUTOCONNECT | FLAG_MAP_BUFFERS, *param, 1) < 0 { P.stream_destroy(a.stream); free(a); return; }
		array_add(*s.apps, a);
	}
}

on_global_remove :: (data: *void, id: u32) #c_call {
	s := cast(*Screen) data;
	push_context s.ctx {
		for s.own_clients if it == id remove it;
		for s.apps if it.node == id { P.stream_destroy(it.stream); free(it); remove it; }
	}
}

REGISTRY_EVENTS := Pw_Registry_Events.{version = 0, global = on_global, global_remove = on_global_remove};

on_audio_process :: (data: *void) #c_call {
	a := cast(*App_Audio) data;
	s := a.s;
	push_context s.ctx {
		defer reset_temporary_storage();
		b := P.stream_dequeue_buffer(a.stream);
		if !b return;
		defer P.stream_queue_buffer(a.stream, b);
		sb := b.buffer;
		if !sb || sb.n_datas < 1 || !sb.datas return;
		d := sb.datas;
		ch := d.chunk;
		if !d.data || !ch || !d.maxsize || (ch.flags & CHUNK_CORRUPTED) return;
		off := ch.offset % d.maxsize;
		n := min(ch.size, d.maxsize - off) / 8; // stereo frames
		pcm := cast(*float32) (cast(*u8) d.data + off);
		if n > MIX / 2 n = MIX / 2;
		if a.pos < s.out_pos a.pos = s.out_pos;
		if a.pos + n - s.out_pos > MIX mix_emit(s, a.pos + n - MIX);
		for i: 0..n - 1 s.mix[(a.pos + i) % MIX] += (pcm[2 * i] + pcm[2 * i + 1]) * 0.5;
		a.pos += n;
		// out up to where every app that plays has reached, but never more than LAG behind the furthest
		lo, hi := a.pos, a.pos;
		for s.apps if it.pos > s.out_pos { lo = min(lo, it.pos); hi = max(hi, it.pos); }
		mix_emit(s, max(lo, hi - LAG));
	}
}

AUDIO_EVENTS := Pw_Stream_Events.{version = 2, process = on_audio_process};

mix_emit :: (s: *Screen, upto: s64) {
	n := upto - s.out_pos;
	if n <= 0 return;
	out := NewArray(n, float32,, temp);
	for i: 0..n - 1 {
		k := (s.out_pos + i) % MIX;
		out[i] = clamp(s.mix[k], -1, 1);
		s.mix[k] = 0;
	}
	s.out_pos = upto;
	c := s.c;
	locks.lock(*c.mu);
	if !atomic_load(*c.quit) c.on_audio(c.user, out);
	locks.unlock(*c.mu);
}

// ---- SPA pods: what we ask for, and the negotiated format, parsed with every size checked.

Pod :: struct {
	buf: [512]u8 #align 8;
	n: int;
}

put :: (p: *Pod, vals: ..u32) {
	for vals { (cast(*u32) (p.buf.data + p.n)).* = it; p.n += 4; }
}

// An object pod: its type and param id, then prop_* props; pod_end fills in its size.
pod_begin :: (p: *Pod, type: u32, id: u32) { put(p, 0, T_OBJECT, type, id); }
pod_end :: (p: *Pod) { (cast(*u32) p.buf.data).* = xx (p.n - 8); }
prop_id :: (p: *Pod, key: u32, v: u32) { put(p, key, 0, 4, T_ID, v, 0); }
prop_int :: (p: *Pod, key: u32, v: u32) { put(p, key, 0, 4, T_INT, v, 0); }

video_format :: (p: *Pod, fps: int) {
	pod_begin(p, OBJ_FORMAT, PARAM_ENUM_FORMAT);
	prop_id(p, FORMAT_MEDIA_TYPE, MEDIA_VIDEO);
	prop_id(p, FORMAT_MEDIA_SUBTYPE, SUBTYPE_RAW);
	FORMATS :: u32.[FMT_BGRx, FMT_BGRx, FMT_RGBx, FMT_BGRA, FMT_RGBA, FMT_xRGB, FMT_xBGR, FMT_RGB, FMT_BGR]; // default first
	put(p, FORMAT_VIDEO_FORMAT, 0, xx (16 + FORMATS.count * 4), T_CHOICE, CHOICE_ENUM, 0, 4, T_ID);
	put(p, ..FORMATS);
	if p.n % 8 put(p, 0);
	put(p, FORMAT_VIDEO_SIZE, 0, 16 + 3 * 8, T_CHOICE, CHOICE_RANGE, 0, 8, T_RECTANGLE, 1920, 1080, 1, 1, 16384, 16384);
	put(p, FORMAT_VIDEO_FRAMERATE, 0, 16 + 3 * 8, T_CHOICE, CHOICE_RANGE, 0, 8, T_FRACTION, xx fps, 1, 0, 1, 1000, 1);
	pod_end(p);
}

audio_format :: (p: *Pod) {
	pod_begin(p, OBJ_FORMAT, PARAM_ENUM_FORMAT);
	prop_id(p, FORMAT_MEDIA_TYPE, MEDIA_AUDIO);
	prop_id(p, FORMAT_MEDIA_SUBTYPE, SUBTYPE_RAW);
	prop_id(p, FORMAT_AUDIO_FORMAT, AUDIO_F32);
	prop_int(p, FORMAT_AUDIO_RATE, 48000);
	prop_int(p, FORMAT_AUDIO_CHANNELS, 2); // a mono port gets only the left channel linked
	put(p, FORMAT_AUDIO_POSITION, 0, 16, T_ARRAY, 4, T_ID, CHANNEL_FL, CHANNEL_FR);
	pod_end(p);
}

// Plain memory only: the conversion reads the pixels on the CPU.
buffers_param :: (p: *Pod) {
	pod_begin(p, OBJ_PARAM_BUFFERS, PARAM_BUFFERS);
	put(p, BUFFERS_DATA_TYPE, 0, 16 + 4, T_CHOICE, CHOICE_FLAGS, 0, 4, T_INT, (1 << DATA_MEM_PTR) | (1 << DATA_MEM_FD), 0);
	pod_end(p);
}

Format :: struct { media: u32; format: u32; w, h: int; }

// A Format object's media type, video format and size. A value may also come as a Choice (its default
// is the first value).
parse_format :: (pod: *u8) -> Format {
	f: Format;
	u :: (p: *u8, i: int) -> u32 #expand { return (cast(*u32) (p + i * 4)).*; }
	size := cast(int) u(pod, 0);
	if u(pod, 1) != T_OBJECT || size < 8 || size > 65536 return f;
	body := pod + 8;
	at := 8; // past the object's type and id
	while at + 16 <= size {
		key, vsize, vtype := u(body + at, 0), cast(int) u(body + at, 2), u(body + at, 3);
		v := body + at + 16;
		if vsize > size - at - 16 return f;
		if vtype == T_CHOICE && vsize >= 16 { // choice type, flags, child size, child type, then the values
			csize, ctype := cast(int) u(v, 2), u(v, 3);
			if csize > vsize - 16 return .{};
			vtype, v = ctype, v + 16;
			vsize = csize;
		}
		if key == FORMAT_MEDIA_TYPE && vtype == T_ID && vsize >= 4 f.media = u(v, 0);
		if key == FORMAT_VIDEO_FORMAT && vtype == T_ID && vsize >= 4 f.format = u(v, 0);
		if key == FORMAT_VIDEO_SIZE && vtype == T_RECTANGLE && vsize >= 8 { f.w, f.h = u(v, 0), u(v, 1); }
		at += 16 + ((cast(int) u(body + at, 2) + 7) & ~7);
	}
	return f;
}

T_ID :: 3; T_INT :: 4; T_RECTANGLE :: 10; T_FRACTION :: 11; T_ARRAY :: 13; T_OBJECT :: 15; T_CHOICE :: 19;
CHOICE_RANGE :: 1; CHOICE_ENUM :: 3; CHOICE_FLAGS :: 4;
OBJ_FORMAT :: 0x40003; OBJ_PARAM_BUFFERS :: 0x40004;
PARAM_ENUM_FORMAT :: 3; PARAM_FORMAT :: 4; PARAM_BUFFERS :: 5;
FORMAT_MEDIA_TYPE :: 1; FORMAT_MEDIA_SUBTYPE :: 2;
FORMAT_AUDIO_FORMAT :: 0x10001; FORMAT_AUDIO_RATE :: 0x10003; FORMAT_AUDIO_CHANNELS :: 0x10004; FORMAT_AUDIO_POSITION :: 0x10005;
CHANNEL_FL :: 3; CHANNEL_FR :: 4;
FORMAT_VIDEO_FORMAT :: 0x20001; FORMAT_VIDEO_SIZE :: 0x20003; FORMAT_VIDEO_FRAMERATE :: 0x20004;
MEDIA_AUDIO :: 1; MEDIA_VIDEO :: 2; SUBTYPE_RAW :: 1;
AUDIO_F32 :: 0x11B;
FMT_RGBx :: 7; FMT_BGRx :: 8; FMT_xRGB :: 9; FMT_xBGR :: 10; FMT_RGBA :: 11; FMT_BGRA :: 12; FMT_RGB :: 15; FMT_BGR :: 16;
BUFFERS_DATA_TYPE :: 6;
DATA_MEM_PTR :: 1; DATA_MEM_FD :: 2;
CHUNK_CORRUPTED :: 1;
FLAG_AUTOCONNECT :: 0x1; FLAG_MAP_BUFFERS :: 0x4;
STATE_ERROR :: -1; STATE_UNCONNECTED :: 0;
ANY_ID :: 0xFFFF_FFFF;

// ---- libpipewire 0.3 (x86_64 layouts, checked against its 1.0 headers)

Spa_Hook :: struct { data: [6]*void; }
Spa_Dict :: struct { flags, n_items: u32; items: *Spa_Dict_Item; }
Spa_Dict_Item :: struct { key, value: *u8; }
Spa_Chunk :: struct { offset, size: u32; stride, flags: s32; }
Spa_Data :: struct { type, flags: u32; fd: s64; mapoffset, maxsize: u32; data: *void; chunk: *Spa_Chunk; }
Spa_Buffer :: struct { n_metas, n_datas: u32; metas: *void; datas: *Spa_Data; }
Pw_Buffer :: struct { buffer: *Spa_Buffer; user_data: *void; size, requested, time: u64; }
#assert size_of(Spa_Hook) == 48 && size_of(Spa_Data) == 40 && size_of(Pw_Buffer) == 40;

Pw_Stream_Events :: struct {
	version: u32;
	destroy: *void;
	state_changed: (data: *void, old: s32, state: s32, error: *u8) #c_call;
	control_info, io_changed: *void;
	param_changed: (data: *void, id: u32, param: *u8) #c_call;
	add_buffer, remove_buffer: *void;
	process: (data: *void) #c_call;
	drained, command, trigger_done: *void;
}
#assert size_of(Pw_Stream_Events) == 96;

Pw_Registry_Events :: struct {
	version: u32;
	global: (data: *void, id: u32, permissions: u32, type: *u8, version: u32, props: *Spa_Dict) #c_call;
	global_remove: (data: *void, id: u32) #c_call;
}

// A core's or registry's method: their spa_interface holds the methods table (at offset) and its object.
Spa_Interface :: struct { type: *u8; version: u32; funcs: *u8; data: *void; }
method :: (obj: *void, offset: int) -> *void { return (cast(**void) ((cast(*Spa_Interface) obj).funcs + offset)).*; }
iface_data :: (obj: *void) -> *void { return (cast(*Spa_Interface) obj).data; }

// A property of a PipeWire dict ("" when missing), at most 256 entries and 1 KiB a value.
dict :: (d: *Spa_Dict, key: string) -> string {
	for i: 0..min(cast(int) d.n_items, 256) - 1 {
		it := d.items[i];
		if it.key && it.value && cstr(it.key) == key return cstr(it.value);
	}
	return "";
}

cstr :: (p: *u8) -> string {
	if !p return "";
	n := 0;
	while n < 1024 && p[n] n += 1;
	return .{n, p};
}

P: struct {
	init: (argc: *s32, argv: ***u8) #c_call;
	thread_loop_new: (name: *u8, props: *void) -> *void #c_call;
	thread_loop_get_loop: (l: *void) -> *void #c_call;
	thread_loop_start: (l: *void) -> s32 #c_call;
	thread_loop_stop: (l: *void) #c_call;
	thread_loop_lock: (l: *void) #c_call;
	thread_loop_unlock: (l: *void) #c_call;
	thread_loop_destroy: (l: *void) #c_call;
	context_new: (loop: *void, props: *void, user_size: u64) -> *void #c_call;
	context_connect_fd: (ctx: *void, fd: s32, props: *void, user_size: u64) -> *void #c_call;
	context_connect: (ctx: *void, props: *void, user_size: u64) -> *void #c_call;
	context_destroy: (ctx: *void) #c_call;
	core_disconnect: (core: *void) -> s32 #c_call;
	properties_new_string: (s: *u8) -> *void #c_call;
	stream_new: (core: *void, name: *u8, props: *void) -> *void #c_call;
	stream_add_listener: (s: *void, hook: *Spa_Hook, events: *Pw_Stream_Events, data: *void) #c_call;
	stream_connect: (s: *void, direction: u32, target: u32, flags: u32, params: **u8, n: u32) -> s32 #c_call;
	stream_update_params: (s: *void, params: **u8, n: u32) -> s32 #c_call;
	stream_dequeue_buffer: (s: *void) -> *Pw_Buffer #c_call;
	stream_queue_buffer: (s: *void, b: *Pw_Buffer) -> s32 #c_call;
	stream_destroy: (s: *void) #c_call;
	proxy_destroy: (p: *void) #c_call;
};
pw_state: s32; // atomic: 0 not tried, 1 loaded, 2 missing

pw_load :: () -> bool {
	if atomic_load(*pw_state) == 0 {
		lib := dlopen("libpipewire-0.3.so.0", RTLD_NOW);
		atomic_store(*pw_state, cast(s32) ifx lib && load_syms(lib, *P, "pw_") then 1 else 2);
	}
	return atomic_load(*pw_state) == 1;
}

load_syms :: (lib: *void, table: *$T, prefix: string) -> bool {
	for type_info(T).members {
		p := dlsym(lib, temp_c_string(join(prefix, it.name,, temp)));
		if !p return false;
		(cast(**void) (cast(*u8) table + it.offset_in_bytes)).* = p;
	}
	return true;
}

// ---- xdg-desktop-portal's ScreenCast over libdbus

Portal :: struct {
	conn: *void;
	sender: string; // our unique name as the portal puts it in request paths (":1.42" -> "1_42")
	session: string; // heap
	token: int;
	closed: bool; // the session ended (the desktop's own Stop)
}

DESKTOP :: "org.freedesktop.portal.Desktop";
DESKTOP_PATH :: "/org/freedesktop/portal/desktop";
SCREENCAST :: "org.freedesktop.portal.ScreenCast";

// The portal's dialog, then its PipeWire fd and the node to stream: -1 when it failed (c.error says
// why) or was cancelled.
portal_open :: (p: *Portal, c: *Capture) -> s32, u32 {
	if !dbus_load() { c.error = "Screen sharing needs D-Bus and xdg-desktop-portal."; return -1, 0; }
	err: DBus_Error;
	B.error_init(*err);
	p.conn = B.bus_get_private(0 /*SESSION*/, *err);
	B.error_free(*err);
	if !p.conn { c.error = "Screen sharing needs a D-Bus session."; return -1, 0; }
	B.connection_set_exit_on_disconnect(p.conn, 0);
	name := cstr(B.bus_get_unique_name(p.conn));
	if name.count < 2 || name[0] != #char ":" { c.error = "Screen sharing needs a D-Bus session."; return -1, 0; }
	p.sender = replace(slice(name, 1, name.count - 1), ".", "_");
	B.error_init(*err);
	B.bus_add_match(p.conn, "type='signal',interface='org.freedesktop.portal.Request',member='Response'", *err);
	B.error_free(*err);
	B.error_init(*err);
	B.bus_add_match(p.conn, "type='signal',interface='org.freedesktop.portal.Session',member='Closed'", *err);
	B.error_free(*err);

	_, ok := property_u32(p, "version");
	if !ok { c.error = "Screen sharing needs xdg-desktop-portal with a ScreenCast backend."; return -1, 0; }
	sources := property_u32(p, "AvailableSourceTypes");
	cursors := property_u32(p, "AvailableCursorModes");

	code, results := request(p, c, "CreateSession", Opt.[.{"session_handle_token", "fastcord", 0, #char "s"}]);
	if code != 0 { set_error(c, code); return -1, 0; }
	{
		defer B.message_unref(results);
		v, found := results_get(results, "session_handle");
		t := B.message_iter_get_arg_type(*v);
		if !found || (t != #char "s" && t != #char "o") { c.error = "The screen sharing portal didn't open a session."; return -1, 0; }
		sp: *u8;
		B.message_iter_get_basic(*v, *sp);
		p.session = copy_string(cstr(sp));
	}

	types := sources & 3; // monitors and windows
	opts: [..]Opt;
	opts.allocator = temp;
	array_add(*opts, .{"types", "", ifx types then types else 1, #char "u"});
	array_add(*opts, .{"multiple", "", 0, #char "b"});
	if cursors & 2 array_add(*opts, .{"cursor_mode", "", 2, #char "u"}); // drawn into the picture
	code, results = request(p, c, "SelectSources", opts);
	if code != 0 { set_error(c, code); return -1, 0; }
	B.message_unref(results);

	code, results = request(p, c, "Start", Opt.[]);
	if code != 0 { set_error(c, code); return -1, 0; }
	node: u32;
	got := false;
	{
		defer B.message_unref(results);
		v, found := results_get(results, "streams");
		if found && B.message_iter_get_arg_type(*v) == #char "a" {
			arr, st: DBus_Iter;
			B.message_iter_recurse(*v, *arr);
			if B.message_iter_get_arg_type(*arr) == #char "r" {
				B.message_iter_recurse(*arr, *st);
				if B.message_iter_get_arg_type(*st) == #char "u" { B.message_iter_get_basic(*st, *node); got = true; }
			}
		}
	}
	if !got { c.error = "The screen sharing portal gave no stream."; return -1, 0; }

	m := B.message_new_method_call(DESKTOP, DESKTOP_PATH, SCREENCAST, "OpenPipeWireRemote");
	if !m { c.error = "Couldn't open the screen stream."; return -1, 0; }
	defer B.message_unref(m);
	it, arr: DBus_Iter;
	B.message_iter_init_append(m, *it);
	append_path(*it, p.session);
	B.message_iter_open_container(*it, #char "a", "{sv}", *arr);
	B.message_iter_close_container(*it, *arr);
	reply := call(p, m);
	fd: s32 = -1;
	if reply {
		if B.message_iter_init(reply, *it) && B.message_iter_get_arg_type(*it) == #char "h" B.message_iter_get_basic(*it, *fd);
		B.message_unref(reply);
	}
	if fd < 0 c.error = "Couldn't open the screen stream.";
	return fd, node;
}

set_error :: (c: *Capture, code: s32) {
	if code == 2 c.error = "The screen sharing portal failed.";
	else if code < 0 && !atomic_load(*c.quit) c.error = "The screen sharing portal didn't answer.";
	// 1: cancelled in the dialog
}

// Waits for the session to close (the desktop's Stop), at most ms.
portal_poll :: (p: *Portal, ms: s32) {
	if !B.connection_read_write(p.conn, ms) { p.closed = true; return; }
	while true {
		m := B.connection_pop_message(p.conn);
		if !m break;
		if B.message_is_signal(m, "org.freedesktop.portal.Session", "Closed") && cstr(B.message_get_path(m)) == p.session p.closed = true;
		B.message_unref(m);
	}
}

portal_close :: (p: *Portal) {
	if !p.conn return;
	if p.session {
		m := B.message_new_method_call(DESKTOP, temp_c_string(p.session), "org.freedesktop.portal.Session", "Close");
		if m { B.connection_send(p.conn, m, null); B.connection_flush(p.conn); B.message_unref(m); }
	}
	B.connection_close(p.conn);
	B.connection_unref(p.conn);
	free(p.session);
	free(p.sender);
}

Opt :: struct { key: string; s: string; u: u32; kind: u8; } // kind: 's', 'u' or 'b'

// A ScreenCast method that answers through a Request object, and its Response: the code (0 done,
// 1 cancelled, 2 failed, -1 no answer or capture_stop) and the results (unref them when 0).
request :: (p: *Portal, c: *Capture, method: string, opts: []Opt) -> s32, *void {
	p.token += 1;
	token := tprint("fastcord%", p.token);
	want := tprint("/org/freedesktop/portal/desktop/request/%/%", p.sender, token);
	m := B.message_new_method_call(DESKTOP, DESKTOP_PATH, SCREENCAST, temp_c_string(method));
	if !m return -1, null;
	it, arr: DBus_Iter;
	B.message_iter_init_append(m, *it);
	if p.session append_path(*it, p.session);
	if method == "Start" append_string(*it, ""); // no parent window
	B.message_iter_open_container(*it, #char "a", "{sv}", *arr);
	append_opt(*arr, .{"handle_token", token, 0, #char "s"});
	for opts append_opt(*arr, it);
	B.message_iter_close_container(*it, *arr);
	reply := call(p, m);
	B.message_unref(m);
	if !reply return -1, null;
	handle: *u8;
	if B.message_iter_init(reply, *it) && B.message_iter_get_arg_type(*it) == #char "o" B.message_iter_get_basic(*it, *handle);
	got := ifx handle then copy_string(cstr(handle),, temp) else want; // older portals answer on another path
	B.message_unref(reply);
	// the user may sit in the dialog for a while
	while !atomic_load(*c.quit) {
		if !B.connection_read_write(p.conn, 100) return -1, null;
		while true {
			r := B.connection_pop_message(p.conn);
			if !r break;
			path := cstr(B.message_get_path(r));
			if B.message_is_signal(r, "org.freedesktop.portal.Request", "Response") && (path == got || path == want) {
				code: u32 = 2;
				if B.message_iter_init(r, *it) && B.message_iter_get_arg_type(*it) == #char "u" B.message_iter_get_basic(*it, *code);
				if code == 0 return 0, r;
				B.message_unref(r);
				return cast(s32) min(code, 2), null;
			}
			B.message_unref(r);
		}
	}
	close := B.message_new_method_call(DESKTOP, temp_c_string(got), "org.freedesktop.portal.Request", "Close");
	if close { B.connection_send(p.conn, close, null); B.connection_flush(p.conn); B.message_unref(close); }
	return -1, null;
}

// A Response's results (a{sv}, after the code): the value under key.
results_get :: (r: *void, key: string) -> DBus_Iter, bool {
	it, arr, e, v: DBus_Iter;
	if !B.message_iter_init(r, *it) || !B.message_iter_next(*it) || B.message_iter_get_arg_type(*it) != #char "a" return v, false;
	B.message_iter_recurse(*it, *arr);
	for 0..255 {
		if B.message_iter_get_arg_type(*arr) != #char "e" break;
		B.message_iter_recurse(*arr, *e);
		k: *u8;
		if B.message_iter_get_arg_type(*e) == #char "s" {
			B.message_iter_get_basic(*e, *k);
			if cstr(k) == key && B.message_iter_next(*e) && B.message_iter_get_arg_type(*e) == #char "v" {
				B.message_iter_recurse(*e, *v);
				return v, true;
			}
		}
		if !B.message_iter_next(*arr) break;
	}
	return v, false;
}

// A ScreenCast property (0, false when the portal or the property is missing).
property_u32 :: (p: *Portal, prop: string) -> u32, bool {
	m := B.message_new_method_call(DESKTOP, DESKTOP_PATH, "org.freedesktop.DBus.Properties", "Get");
	if !m return 0, false;
	defer B.message_unref(m);
	it, v: DBus_Iter;
	B.message_iter_init_append(m, *it);
	append_string(*it, SCREENCAST);
	append_string(*it, prop);
	reply := call(p, m);
	if !reply return 0, false;
	defer B.message_unref(reply);
	if !B.message_iter_init(reply, *it) || B.message_iter_get_arg_type(*it) != #char "v" return 0, false;
	B.message_iter_recurse(*it, *v);
	if B.message_iter_get_arg_type(*v) != #char "u" return 0, false;
	n: u32;
	B.message_iter_get_basic(*v, *n);
	return n, true;
}

call :: (p: *Portal, m: *void) -> *void {
	err: DBus_Error;
	B.error_init(*err);
	reply := B.connection_send_with_reply_and_block(p.conn, m, 10000, *err);
	B.error_free(*err);
	return reply;
}

append_string :: (it: *DBus_Iter, s: string) { c := temp_c_string(s); B.message_iter_append_basic(it, #char "s", *c); }
append_path :: (it: *DBus_Iter, s: string) { c := temp_c_string(s); B.message_iter_append_basic(it, #char "o", *c); }

append_opt :: (arr: *DBus_Iter, o: Opt) {
	e, v: DBus_Iter;
	B.message_iter_open_container(arr, #char "e", null, *e);
	append_string(*e, o.key);
	sig: [2]u8 = .[o.kind, 0];
	B.message_iter_open_container(*e, #char "v", sig.data, *v);
	if o.kind == #char "s" append_string(*v, o.s);
	else { u := o.u; B.message_iter_append_basic(*v, o.kind, *u); } // u and b are both 32 bits
	B.message_iter_close_container(*e, *v);
	B.message_iter_close_container(arr, *e);
}

DBus_Error :: struct { name, message: *u8; dummy: u32; padding: *void; }
DBus_Iter :: struct { data: [16]u64; } // DBusMessageIter (72 bytes), opaque

B: struct {
	threads_init_default: () -> u32 #c_call;
	error_init: (e: *DBus_Error) #c_call;
	error_free: (e: *DBus_Error) #c_call;
	bus_get_private: (type: s32, e: *DBus_Error) -> *void #c_call;
	bus_get_unique_name: (c: *void) -> *u8 #c_call;
	bus_add_match: (c: *void, rule: *u8, e: *DBus_Error) #c_call;
	connection_set_exit_on_disconnect: (c: *void, exit: u32) #c_call;
	connection_read_write: (c: *void, timeout_ms: s32) -> u32 #c_call;
	connection_pop_message: (c: *void) -> *void #c_call;
	connection_send: (c: *void, m: *void, serial: *u32) -> u32 #c_call;
	connection_send_with_reply_and_block: (c: *void, m: *void, timeout_ms: s32, e: *DBus_Error) -> *void #c_call;
	connection_flush: (c: *void) #c_call;
	connection_close: (c: *void) #c_call;
	connection_unref: (c: *void) #c_call;
	message_new_method_call: (dest: *u8, path: *u8, iface: *u8, method: *u8) -> *void #c_call;
	message_unref: (m: *void) #c_call;
	message_is_signal: (m: *void, iface: *u8, name: *u8) -> u32 #c_call;
	message_get_path: (m: *void) -> *u8 #c_call;
	message_iter_init: (m: *void, it: *DBus_Iter) -> u32 #c_call;
	message_iter_init_append: (m: *void, it: *DBus_Iter) #c_call;
	message_iter_get_arg_type: (it: *DBus_Iter) -> s32 #c_call;
	message_iter_get_basic: (it: *DBus_Iter, value: *void) #c_call;
	message_iter_append_basic: (it: *DBus_Iter, type: s32, value: *void) -> u32 #c_call;
	message_iter_open_container: (it: *DBus_Iter, type: s32, signature: *u8, sub: *DBus_Iter) -> u32 #c_call;
	message_iter_close_container: (it: *DBus_Iter, sub: *DBus_Iter) -> u32 #c_call;
	message_iter_next: (it: *DBus_Iter) -> u32 #c_call;
	message_iter_recurse: (it: *DBus_Iter, sub: *DBus_Iter) #c_call;
};
dbus_state: s32; // atomic: 0 not tried, 1 loaded, 2 missing

dbus_load :: () -> bool {
	if atomic_load(*dbus_state) == 0 {
		lib := dlopen("libdbus-1.so.3", RTLD_NOW);
		ok := lib && load_syms(lib, *B, "dbus_");
		if ok B.threads_init_default();
		atomic_store(*dbus_state, cast(s32) ifx ok then 1 else 2);
	}
	return atomic_load(*dbus_state) == 1;
}
