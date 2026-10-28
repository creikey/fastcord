// ALSA through libasound.so.2, loaded at run time: on desktops its "default" device is the PipeWire or
// PulseAudio plugin. Output: f32 stereo 48 kHz pulled from mix() by a thread blocking in snd_pcm_writei;
// capture: f32 mono by a thread blocking in snd_pcm_readi. Xruns recover with snd_pcm_recover; a device
// that fails to recover (unplugged) is reopened. Without libasound device_init fails and the app runs
// without audio. Not compiled on macOS or Windows.

#scope_export

Device_Info :: struct {
	id: u32;
	name: string;
	uid: string; // the ALSA PCM name
	is_default: bool;
}

// list_devices: each sound card's "sysdefault" PCM that can play (or record). Cached: name hints probe
// the cards, so they are refreshed at most every DEVICE_LIST_TTL_MS.
list_devices :: (input: bool, allocator := context.allocator) -> []Device_Info {
	out: [..]Device_Info;
	out.allocator = allocator;
	locks.guard(*lx.mu);
	if !load() return out;
	now := to_milliseconds(current_time_monotonic());
	if !lx.listed_ms || now - lx.listed_ms > DEVICE_LIST_TTL_MS { refresh_devices(); lx.listed_ms = now; }
	for lx.devices if it.input == input
		array_add(*out, .{id = it.id, name = copy_string(it.name,, allocator), uid = copy_string(it.uid,, allocator)});
	return out;
}

selected_device :: (input: bool) -> u32 { return ifx input then lx.sel_input else lx.sel_output; }

// select_device: 0 = follow the system default.
select_device :: (input: bool, id: u32) {
	{
		locks.guard(*lx.mu);
		name := "";
		for lx.devices if id && it.id == id && it.input == input name = it.uid;
		if input { lx.sel_input = id; free(lx.in_name); lx.in_name = copy_string(name); }
		else { lx.sel_output = id; free(lx.out_name); lx.out_name = copy_string(name); }
	}
	apply_device_selection();
}

device_rate_changed :: () {}

// apply_device_selection reopens a running stream whose device is no longer the selected one.
apply_device_selection :: () {
	if !lx.lib return;
	locks.guard(*st.device_mu);
	for s: (*Stream).[*lx.out, *lx.inp] {
		if !s.started || device_name(s.capture) == s.dev continue;
		stop_stream(s);
		if !start_stream(s) && !s.capture st.running = false;
	}
}

#scope_module

device_init :: () -> bool {
	{
		locks.guard(*lx.mu);
		if !load() return false;
	}
	pcm, _ := open_pcm(false); // an output device exists; also measures the latency
	if !pcm return false;
	fn.snd_pcm_close(pcm);
	return true;
}

device_shutdown :: () {
	stop_stream(*lx.out);
	stop_stream(*lx.inp);
	st.running = false;
}

device_start :: () {
	if st.running return;
	st.running = start_stream(*lx.out);
}

device_stop :: () {
	if !st.running return;
	stop_stream(*lx.out);
	st.running = false;
}

device_capture_start :: () -> bool { return start_stream(*lx.inp); }
device_capture_stop :: () { stop_stream(*lx.inp); }

#scope_file

libc :: #system_library "libc"; // dlopen/dlsym are in libdl before glibc 2.34; the link adds -ldl
dlopen :: (file: *u8, mode: s32) -> *void #foreign libc;
dlsym :: (handle: *void, name: *u8) -> *void #foreign libc;
c_free :: (p: *void) #foreign libc "free";
RTLD_NOW :: 2;

SND_PCM_STREAM_PLAYBACK :: 0;
SND_PCM_STREAM_CAPTURE :: 1;
SND_PCM_NONBLOCK :: 1; // open only: a busy hw device fails instead of blocking
SND_PCM_FORMAT_FLOAT_LE :: 14;
SND_PCM_ACCESS_RW_INTERLEAVED :: 3;
LATENCY_US :: 40_000; // the buffer; snd_pcm_set_params makes periods a quarter of it (10 ms)
MAX_PERIOD :: 2048;
DEVICE_LIST_TTL_MS :: 2000;

// Every libasound entry point used, resolved by name with dlsym (snd_pcm_t and hints are opaque).
Alsa :: struct {
	snd_pcm_open: (pcm: **void, name: *u8, stream: s32, mode: s32) -> s32 #c_call;
	snd_pcm_close: (pcm: *void) -> s32 #c_call;
	snd_pcm_nonblock: (pcm: *void, nonblock: s32) -> s32 #c_call;
	snd_pcm_set_params: (pcm: *void, format: s32, access: s32, channels: u32, rate: u32, soft_resample: s32, latency_us: u32) -> s32 #c_call;
	snd_pcm_get_params: (pcm: *void, buffer_size: *u64, period_size: *u64) -> s32 #c_call;
	snd_pcm_writei: (pcm: *void, buf: *void, frames: u64) -> s64 #c_call;
	snd_pcm_readi: (pcm: *void, buf: *void, frames: u64) -> s64 #c_call;
	snd_pcm_recover: (pcm: *void, err: s32, silent: s32) -> s32 #c_call;
	snd_pcm_drop: (pcm: *void) -> s32 #c_call;
	snd_device_name_hint: (card: s32, iface: *u8, hints: ***void) -> s32 #c_call;
	snd_device_name_get_hint: (hint: *void, id: *u8) -> *u8 #c_call; // malloc'd, or null
	snd_device_name_free_hint: (hints: **void) -> s32 #c_call;
}
fn: Alsa;

Stream :: struct {
	capture: bool;
	pcm: *void;
	period: int;
	dev: string; // the PCM name opened ("" = default)
	thread: Thread;
	started: bool;
	quit: bool; // atomic
}

Device :: struct { id: u32; name: string; uid: string; input: bool; }

lx: struct {
	lib: *void;
	load_tried: bool;
	mu: locks.Mutex; // the other fields but the streams (libasound locks its own global config since 1.1.2)
	devices: [..]Device;
	listed_ms: s64;
	sel_input, sel_output: u32;
	in_name, out_name: string;
	out := Stream.{capture = false};
	inp := Stream.{capture = true};
};

// load resolves libasound once (under lx.mu).
load :: () -> bool {
	if lx.load_tried return lx.lib != null;
	lx.load_tried = true;
	lib := dlopen("libasound.so.2", RTLD_NOW);
	if !lib return false;
	for type_info(Alsa).members {
		f := dlsym(lib, temp_c_string(it.name));
		if !f return false;
		(cast(**void) (cast(*u8) *fn + it.offset_in_bytes)).* = f;
	}
	lx.lib = lib;
	return true;
}

device_name :: (capture: bool) -> string {
	locks.guard(*lx.mu);
	return copy_string(ifx capture then lx.in_name else lx.out_name,, temp);
}

// open_pcm opens the selected device (else "default") for blocking I/O; null if it can't.
open_pcm :: (capture: bool) -> *void, period: int, dev: string {
	dev := device_name(capture);
	pcm: *void;
	if fn.snd_pcm_open(*pcm, temp_c_string(ifx dev then dev else "default"), xx ifx capture then SND_PCM_STREAM_CAPTURE else SND_PCM_STREAM_PLAYBACK, SND_PCM_NONBLOCK) < 0 return null, 0, "";
	fn.snd_pcm_nonblock(pcm, 0);
	ch: u32 = xx ifx capture then 1 else CHANNELS;
	if fn.snd_pcm_set_params(pcm, SND_PCM_FORMAT_FLOAT_LE, SND_PCM_ACCESS_RW_INTERLEAVED, ch, SAMPLE_RATE, 1, LATENCY_US) < 0 {
		fn.snd_pcm_close(pcm);
		return null, 0, "";
	}
	buffer, period: u64;
	fn.snd_pcm_get_params(pcm, *buffer, *period);
	if !capture st.latency = cast(float64) buffer / SAMPLE_RATE;
	return pcm, clamp(cast(int) period, 64, MAX_PERIOD), dev;
}

// start_stream opens the device here (so a failure is reported) and hands it to the stream's thread.
start_stream :: (s: *Stream) -> bool {
	if s.started return true;
	dev: string;
	s.pcm, s.period, dev = open_pcm(s.capture);
	if !s.pcm return false;
	s.dev = copy_string(dev);
	atomic_store(*s.quit, false);
	thread_init(*s.thread, stream_thread);
	s.thread.data = s;
	thread_start(*s.thread);
	s.started = true;
	return true;
}

stop_stream :: (s: *Stream) {
	if !s.started return;
	atomic_store(*s.quit, true); // the thread returns within a period
	thread_is_done(*s.thread, -1);
	thread_deinit(*s.thread);
	free(s.dev);
	s.dev = "";
	s.started = false;
}

stream_thread :: (th: *Thread) -> s64 {
	s := cast(*Stream) th.data;
	buf: [MAX_PERIOD * CHANNELS]float32;
	ch := ifx s.capture then 1 else CHANNELS;
	while !atomic_load(*s.quit) {
		if !s.pcm {
			// the device went away: retry the selected one (or the default) until it is back
			sleep_milliseconds(200);
			s.pcm, s.period = open_pcm(s.capture);
			reset_temporary_storage();
			continue;
		}
		r: s64;
		if s.capture {
			r = fn.snd_pcm_readi(s.pcm, buf.data, xx s.period);
			if r > 0 ring_write(*st.capture, .{r, buf.data});
		} else {
			mix(.{s.period * ch, buf.data});
			done := 0;
			while done < s.period {
				r = fn.snd_pcm_writei(s.pcm, *buf[done * ch], xx (s.period - done));
				if r < 0 break;
				done += r;
			}
		}
		if r < 0 && fn.snd_pcm_recover(s.pcm, xx r, 1) < 0 {
			fn.snd_pcm_close(s.pcm);
			s.pcm = null;
		}
	}
	if s.pcm {
		fn.snd_pcm_drop(s.pcm);
		fn.snd_pcm_close(s.pcm);
		s.pcm = null;
	}
	return 0;
}

// refresh_devices rebuilds lx.devices from the PCM name hints (under lx.mu).
refresh_devices :: () {
	for lx.devices { free(it.name); free(it.uid); }
	array_reset_keeping_memory(*lx.devices);
	hints: **void;
	if fn.snd_device_name_hint(-1, "pcm", *hints) < 0 return;
	defer fn.snd_device_name_free_hint(hints);
	hint_string :: (h: *void, id: *u8) -> string {
		c := fn.snd_device_name_get_hint(h, id);
		if !c return "";
		defer c_free(c);
		return copy_string(to_string(c));
	}
	p := hints;
	while p.* {
		defer p += 1;
		uid := hint_string(p.*, "NAME");
		if !begins_with(uid, "sysdefault:") { free(uid); continue; } // one per card, through the plug converter
		desc := hint_string(p.*, "DESC"); // "Card name, PCM name\nDescription"
		io := hint_string(p.*, "IOID"); // "Input", "Output", or none for both
		nl := find_index_from_left(desc, #char "\n");
		name := copy_string(trim(ifx nl >= 0 then slice(desc, 0, nl) else desc));
		free(desc);
		for input: bool.[false, true] {
			if io && io != (ifx input then "Input" else "Output") continue;
			// a stable id from the name: settings keep the uid, selections the id
			h: u32 = 2166136261;
			for 0..uid.count-1 h = (h ^ uid[it]) * 16777619;
			array_add(*lx.devices, .{id = ifx h then h else 1, name = copy_string(name), uid = copy_string(uid), input = input});
		}
		free(io); free(name); free(uid);
	}
}

#import "String";
