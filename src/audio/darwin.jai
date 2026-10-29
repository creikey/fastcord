// CoreAudio: an output unit pulling mix() (DefaultOutput, which follows the system default, or AUHAL on a
// chosen device) and an input-only AUHAL unit for capture. No VoiceProcessingIO: its echo canceller is
// half duplex and zeroed the mic for seconds while others talked, its noise suppression can't be switched
// apart from it, and in bypass it delivers the MacBook mic ~27 dB quieter than AUHAL (all seen live). The
// voice module does echo cancellation, noise suppression and AGC in software, as the official client does.
// AUHAL doesn't resample input (TN2091), so a mic not at 48 kHz goes through an AudioConverter.

#scope_export

// Shared with media's AudioConverter decoder.
AudioStreamBasicDescription :: struct {
	mSampleRate: float64;
	mFormatID: u32;
	mFormatFlags: u32;
	mBytesPerPacket: u32;
	mFramesPerPacket: u32;
	mBytesPerFrame: u32;
	mChannelsPerFrame: u32;
	mBitsPerChannel: u32;
	mReserved: u32;
}

AudioBuffer :: struct {
	mNumberChannels: u32;
	mDataByteSize: u32;
	mData: *void;
}

AudioBufferList :: struct {
	mNumberBuffers: u32;
	mBuffers: [1]AudioBuffer;
}

fourcc :: inline (s: string) -> u32 {
	return ((cast(u32) s[0]) << 24) | ((cast(u32) s[1]) << 16) | ((cast(u32) s[2]) << 8) | (cast(u32) s[3]);
}

kAudioFormatLinearPCM :: 0x6c70636d; // 'lpcm'
kAudioFormatFlagIsFloat :: 1;
kAudioFormatFlagIsSignedInteger :: 4;
kAudioFormatFlagIsPacked :: 8;

Device_Info :: struct {
	id: u32;
	name: string;
	uid: string;
	is_default: bool;
}

// list_devices: devices with input (or output) streams. Enumerating asks
// coreaudiod about every device (24 devices: ~3 ms for the voice page's four
// lists per frame, 78 ms cold), so the lists are kept and HAL listeners mark
// them stale when the devices or the defaults change.
list_devices :: (input: bool, allocator := context.allocator) -> []Device_Info {
	listen_devices();
	if dev.stale {
		dev.stale = false; // a change during the enumeration marks it stale again
		for * dev.lists {
			for it.* { free(it.name); free(it.uid); }
			array_reset(it);
			enumerate_devices(it_index == 1, it);
		}
	}
	src := dev.lists[cast(int) input];
	out := NewArray(src.count, Device_Info,, allocator);
	for src out[it_index] = .{id = it.id, name = copy_string(it.name,, allocator), uid = copy_string(it.uid,, allocator), is_default = it.is_default};
	return out;
}

selected_device :: (input: bool) -> u32 { return ifx input then sel_input else sel_output; }

// select_device: 0 = follow the system default.
select_device :: (input: bool, id: u32) {
	if input sel_input = id;
	else sel_output = id;
	apply_device_selection();
}

// apply_device_selection moves the running capture and the output to the chosen devices.
apply_device_selection :: () {
	locks.guard(*st.device_mu);
	apply_selection_locked();
}

apply_selection_locked :: () {
	if mac.in_unit reopen_input();
	if mac.out_unit && mac.out_dev != sel_output {
		unit := make_output_unit();
		if !unit return;
		was := st.running;
		device_stop();
		AudioUnitUninitialize(mac.out_unit);
		AudioComponentInstanceDispose(mac.out_unit);
		mac.out_unit = unit;
		update_latency();
		if was device_start();
	}
}

#scope_module

device_init :: () -> bool {
	mac.out_unit = make_output_unit();
	if !mac.out_unit return false;
	update_latency();
	addr := AudioObjectPropertyAddress.{fourcc("dOut"), fourcc("glob"), 0};
	AudioObjectAddPropertyListener(SYSTEM_OBJECT, *addr, default_device_changed, null);
	listen_devices();
	return true;
}

device_shutdown :: () {
	if mac.out_unit {
		AudioOutputUnitStop(mac.out_unit);
		AudioUnitUninitialize(mac.out_unit);
		AudioComponentInstanceDispose(mac.out_unit);
	}
	array_free(mac.in_buf);
	mac = .{};
	st.running = false;
}

device_start :: () {
	if !mac.out_unit || st.running return;
	if AudioOutputUnitStart(mac.out_unit) == 0 st.running = true;
}

device_stop :: () {
	if !mac.out_unit || !st.running return;
	AudioOutputUnitStop(mac.out_unit);
	st.running = false;
}

device_capture_start :: () -> bool {
	if !mac.in_buf.count mac.in_buf = NewArray(8192, float32);
	mac.in_unit = open_input_unit();
	return mac.in_unit != null;
}

device_capture_stop :: () {
	if mac.in_unit close_input_unit();
}

// device_rate_changed (update(), device_mu held): the input's rate changed, or the devices did. A chosen
// device that went away (unplugged) falls back to the system default, as the official client does.
device_rate_changed :: () {
	gone := false;
	if sel_input && !dev_prop_u32(sel_input, "livn", "glob") { sel_input = 0; gone = true; }
	if sel_output && !dev_prop_u32(sel_output, "livn", "glob") { sel_output = 0; gone = true; }
	if gone apply_selection_locked();
	else if mac.in_unit && device_rate(mac.rate_dev) != mac.in_rate reopen_input();
}

#scope_file

AudioToolbox :: #library,system,link_always "AudioToolbox";
CoreAudio :: #library,system,link_always "CoreAudio";
CoreFoundation :: #library,system,link_always "CoreFoundation";

OSStatus :: s32;
AudioUnit :: *void;
AudioObjectID :: u32;

AudioComponentDescription :: struct {
	componentType, componentSubType, componentManufacturer, componentFlags, componentFlagsMask: u32;
}

AURenderCallbackStruct :: struct {
	inputProc: (ref: *void, flags: *u32, ts: *void, bus: u32, frames: u32, data: *AudioBufferList) -> OSStatus #c_call;
	inputProcRefCon: *void;
}

AudioObjectPropertyAddress :: struct {
	mSelector, mScope, mElement: u32;
}

AudioComponentFindNext :: (comp: *void, desc: *AudioComponentDescription) -> *void #foreign AudioToolbox;
AudioComponentInstanceNew :: (comp: *void, out: *AudioUnit) -> OSStatus #foreign AudioToolbox;
AudioComponentInstanceDispose :: (unit: AudioUnit) -> OSStatus #foreign AudioToolbox;
AudioUnitInitialize :: (unit: AudioUnit) -> OSStatus #foreign AudioToolbox;
AudioUnitUninitialize :: (unit: AudioUnit) -> OSStatus #foreign AudioToolbox;
AudioUnitSetProperty :: (unit: AudioUnit, id: u32, scope: u32, element: u32, data: *void, size: u32) -> OSStatus #foreign AudioToolbox;
AudioUnitGetProperty :: (unit: AudioUnit, id: u32, scope: u32, element: u32, data: *void, size: *u32) -> OSStatus #foreign AudioToolbox;
AudioUnitRender :: (unit: AudioUnit, flags: *u32, ts: *void, bus: u32, frames: u32, data: *AudioBufferList) -> OSStatus #foreign AudioToolbox;
AudioOutputUnitStart :: (unit: AudioUnit) -> OSStatus #foreign AudioToolbox;
AudioOutputUnitStop :: (unit: AudioUnit) -> OSStatus #foreign AudioToolbox;
AudioObjectGetPropertyDataSize :: (obj: AudioObjectID, addr: *AudioObjectPropertyAddress, qsize: u32, qdata: *void, size: *u32) -> OSStatus #foreign CoreAudio;
AudioObjectGetPropertyData :: (obj: AudioObjectID, addr: *AudioObjectPropertyAddress, qsize: u32, qdata: *void, size: *u32, data: *void) -> OSStatus #foreign CoreAudio;
AudioObjectRemovePropertyListener :: (obj: AudioObjectID, addr: *AudioObjectPropertyAddress, listener: (obj: AudioObjectID, n: u32, addrs: *AudioObjectPropertyAddress, user: *void) -> OSStatus #c_call, user: *void) -> OSStatus #foreign CoreAudio;
AudioObjectAddPropertyListener :: (obj: AudioObjectID, addr: *AudioObjectPropertyAddress, listener: (obj: AudioObjectID, n: u32, addrs: *AudioObjectPropertyAddress, user: *void) -> OSStatus #c_call, user: *void) -> OSStatus #foreign CoreAudio;
AudioConverterNew :: (in_fmt: *AudioStreamBasicDescription, out_fmt: *AudioStreamBasicDescription, out: **void) -> OSStatus #foreign AudioToolbox;
AudioConverterDispose :: (c: *void) -> OSStatus #foreign AudioToolbox;
AudioConverterFillComplexBuffer :: (c: *void, input: (c: *void, packets: *u32, data: *AudioBufferList, desc: **void, user: *void) -> OSStatus #c_call, user: *void, packets: *u32, out: *AudioBufferList, desc: *void) -> OSStatus #foreign AudioToolbox;
CFRelease :: (ref: *void) #foreign CoreFoundation;
CFStringGetCString :: (s: *void, buf: *u8, size: int, encoding: u32) -> bool #foreign CoreFoundation;

SYSTEM_OBJECT :: 1; // kAudioObjectSystemObject
kAudioUnitProperty_StreamFormat :: 8;
kAudioUnitProperty_Latency :: 12;
kAudioUnitProperty_MaximumFramesPerSlice :: 14;
kAudioUnitProperty_SetRenderCallback :: 23;
kAudioOutputUnitProperty_CurrentDevice :: 2000;
kAudioOutputUnitProperty_EnableIO :: 2003;
kAudioOutputUnitProperty_SetInputCallback :: 2005;
SCOPE_GLOBAL :: 0;
SCOPE_INPUT :: 1;
SCOPE_OUTPUT :: 2;

mac: struct {
	out_unit: AudioUnit; // DefaultOutput, or AUHAL on out_dev
	out_dev: u32; // the output unit's chosen device (0 = system default)
	in_unit: AudioUnit; // input-only AUHAL while capturing
	in_rate: float64; // the input device's rate when opened
	rate_dev: u32; // the device whose rate we listen to
	conv: *void; // AudioConverter to 48 kHz when in_rate isn't
	conv_in: []float32; // the input callback's samples, handed to conv by conv_input
	in_buf: []float32;
};

sel_input, sel_output: u32; // 0 = system default

stereo_f32 :: (ch: u32) -> AudioStreamBasicDescription {
	return .{
		mSampleRate = SAMPLE_RATE,
		mFormatID = kAudioFormatLinearPCM,
		mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
		mBytesPerPacket = 4 * ch,
		mFramesPerPacket = 1,
		mBytesPerFrame = 4 * ch,
		mChannelsPerFrame = ch,
		mBitsPerChannel = 32
	};
}

// The device callbacks run on CoreAudio's threads with the context saved by init. They do not use
// temp (which belongs to the thread that called init).
render_cb :: (ref: *void, flags: *u32, ts: *void, bus: u32, frames: u32, data: *AudioBufferList) -> OSStatus #c_call {
	push_context st.ctx {
		buf := data.mBuffers[0];
		mix(.{min(cast(int) frames * CHANNELS, cast(int) buf.mDataByteSize / 4), buf.mData});
	}
	return 0;
}

input_cb :: (ref: *void, flags: *u32, ts: *void, bus: u32, frames: u32, data: *AudioBufferList) -> OSStatus #c_call {
	push_context st.ctx {
		n := min(cast(int) frames, mac.in_buf.count);
		abl := AudioBufferList.{mNumberBuffers = 1};
		abl.mBuffers[0] = .{mNumberChannels = 1, mDataByteSize = cast(u32) (n * 4), mData = mac.in_buf.data};
		fl: u32;
		ok := AudioUnitRender(mac.in_unit, *fl, ts, 1, cast(u32) n, *abl) == 0;
		if ok && !mac.conv ring_write(*st.capture, array_view(mac.in_buf, 0, n));
		else if ok {
			mac.conv_in = array_view(mac.in_buf, 0, n);
			out: [1024]float32;
			while true {
				got: u32 = out.count;
				oabl := AudioBufferList.{mNumberBuffers = 1};
				oabl.mBuffers[0] = .{mNumberChannels = 1, mDataByteSize = out.count * 4, mData = out.data};
				r := AudioConverterFillComplexBuffer(mac.conv, conv_input, null, *got, *oabl, null);
				ring_write(*st.capture, .{got, out.data});
				if r != 0 || got < out.count break;
			}
		}
	}
	return 0;
}

// conv_input hands the converter this callback's samples once, then reports "none yet" (an error of ours:
// zero packets with no error would end the stream and flush the converter's filter state).
conv_input :: (c: *void, packets: *u32, data: *AudioBufferList, desc: **void, user: *void) -> OSStatus #c_call {
	packets.* = xx mac.conv_in.count;
	data.mBuffers[0] = .{mNumberChannels = 1, mDataByteSize = xx (mac.conv_in.count * 4), mData = mac.conv_in.data};
	if !mac.conv_in.count return 1;
	mac.conv_in.count = 0;
	return 0;
}

dev: struct {
	lists: [2][..]Device_Info; // [output, input], heap
	stale := true; // written by devices_changed on a HAL thread
	listening: bool;
};

listen_devices :: () {
	if dev.listening return;
	dev.listening = true;
	for sel: string.["dev#", "dIn ", "dOut"] {
		a := AudioObjectPropertyAddress.{fourcc(sel), fourcc("glob"), 0};
		AudioObjectAddPropertyListener(SYSTEM_OBJECT, *a, devices_changed, null);
	}
}

devices_changed :: (obj: AudioObjectID, n: u32, addrs: *AudioObjectPropertyAddress, user: *void) -> OSStatus #c_call {
	dev.stale = true;
	atomic_store(*st.rate_changed, true); // update() checks the chosen devices are still there
	return 0;
}

enumerate_devices :: (input: bool, out: *[..]Device_Info) {
	a := AudioObjectPropertyAddress.{fourcc("dev#"), fourcc("glob"), 0};
	sz: u32;
	if AudioObjectGetPropertyDataSize(SYSTEM_OBJECT, *a, 0, null, *sz) != 0 || sz == 0 return;
	ids := NewArray(sz / 4, u32,, temp);
	if AudioObjectGetPropertyData(SYSTEM_OBJECT, *a, 0, null, *sz, ids.data) != 0 return;
	def := default_device(input);
	for id: ids {
		sa := AudioObjectPropertyAddress.{fourcc("stm#"), fourcc(ifx input then "inpt" else "outp"), 0};
		ss: u32;
		if AudioObjectGetPropertyDataSize(id, *sa, 0, null, *ss) != 0 || ss == 0 continue;
		if dev_prop_u32(id, "hidn", "glob") != 0 continue;
		uid := cf_string(id, "uid ", temp);
		// another app's VoiceProcessingIO aggregate of the devices it runs on; a device can also be listed twice
		// while a Bluetooth headset switches profile
		if begins_with(uid, "VPAUAggregateAudioDevice") || array_find_uid(out.*, uid) continue;
		array_add(out, .{id = id, name = cf_string(id, "lnam", context.allocator), uid = copy_string(uid), is_default = id == def});
	}
}

array_find_uid :: (devs: []Device_Info, uid: string) -> bool {
	for devs if it.uid == uid return true;
	return false;
}

// open_input_unit: a started input-only AUHAL unit on the selected input device, at the device's rate
// with a converter to 48 kHz when that differs.
open_input_unit :: () -> AudioUnit {
	desc := AudioComponentDescription.{fourcc("auou"), fourcc("ahal"), fourcc("appl"), 0, 0};
	comp := AudioComponentFindNext(null, *desc);
	unit: AudioUnit;
	if !comp || AudioComponentInstanceNew(comp, *unit) != 0 return null;
	on, off: u32 = 1, 0;
	dev := ifx sel_input != 0 then sel_input else default_device(true);
	f := stereo_f32(1);
	f.mSampleRate = device_rate(dev);
	mac.in_rate = f.mSampleRate;
	if f.mSampleRate != SAMPLE_RATE {
		out := stereo_f32(1);
		if AudioConverterNew(*f, *out, *mac.conv) != 0 mac.conv = null;
	}
	// AUHAL doesn't follow a rate change: update() reopens the unit at the new rate
	if dev != mac.rate_dev {
		a := AudioObjectPropertyAddress.{fourcc("nsrt"), fourcc("glob"), 0};
		if mac.rate_dev AudioObjectRemovePropertyListener(mac.rate_dev, *a, rate_changed, null);
		AudioObjectAddPropertyListener(dev, *a, rate_changed, null);
		mac.rate_dev = dev;
	}
	icb := AURenderCallbackStruct.{input_cb, null};
	ok := AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, SCOPE_INPUT, 1, *on, 4) == 0
		&& AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, SCOPE_OUTPUT, 0, *off, 4) == 0
		&& AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, SCOPE_GLOBAL, 0, *dev, 4) == 0
		&& AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, SCOPE_OUTPUT, 1, *f, size_of(type_of(f))) == 0
		&& AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, SCOPE_GLOBAL, 0, *icb, size_of(type_of(icb))) == 0
		&& AudioUnitInitialize(unit) == 0
		&& AudioOutputUnitStart(unit) == 0;
	if !ok {
		AudioComponentInstanceDispose(unit);
		return null;
	}
	return unit;
}

reopen_input :: () {
	close_input_unit();
	mac.in_unit = open_input_unit();
}

device_rate :: (dev: AudioObjectID) -> float64 {
	addr := AudioObjectPropertyAddress.{fourcc("nsrt"), fourcc("glob"), 0};
	rate: float64;
	sz: u32 = 8;
	AudioObjectGetPropertyData(dev, *addr, 0, null, *sz, *rate);
	return rate;
}

rate_changed :: (obj: AudioObjectID, n: u32, addrs: *AudioObjectPropertyAddress, user: *void) -> OSStatus #c_call {
	atomic_store(*st.rate_changed, true);
	return 0;
}

close_input_unit :: () {
	AudioOutputUnitStop(mac.in_unit);
	AudioUnitUninitialize(mac.in_unit);
	AudioComponentInstanceDispose(mac.in_unit);
	mac.in_unit = null;
	if mac.conv AudioConverterDispose(mac.conv);
	mac.conv = null;
}

default_device_changed :: (obj: AudioObjectID, n: u32, addrs: *AudioObjectPropertyAddress, user: *void) -> OSStatus #c_call {
	// DefaultOutput re-routes itself; only the latency estimate changes.
	push_context st.ctx { update_latency(); }
	return 0;
}

// make_output_unit: DefaultOutput, or AUHAL on the chosen output device.
make_output_unit :: () -> AudioUnit {
	desc := AudioComponentDescription.{fourcc("auou"), fourcc(ifx sel_output then "ahal" else "def "), fourcc("appl"), 0, 0};
	comp := AudioComponentFindNext(null, *desc);
	if !comp return null;
	unit: AudioUnit;
	if AudioComponentInstanceNew(comp, *unit) != 0 return null;
	if sel_output AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, SCOPE_GLOBAL, 0, *sel_output, 4);
	mac.out_dev = sel_output;
	f := stereo_f32(CHANNELS);
	if AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, SCOPE_INPUT, 0, *f, size_of(type_of(f))) != 0 {
		AudioComponentInstanceDispose(unit);
		return null;
	}
	maxf: u32 = 4096;
	AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, SCOPE_GLOBAL, 0, *maxf, 4);
	// Small IO buffer for low latency (per-client on macOS; doesn't affect other apps).
	bs: u32 = 256;
	AudioUnitSetProperty(unit, fourcc("fsiz"), SCOPE_GLOBAL, 0, *bs, 4);
	cb := AURenderCallbackStruct.{render_cb, null};
	AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, SCOPE_INPUT, 0, *cb, size_of(type_of(cb)));
	if AudioUnitInitialize(unit) != 0 {
		AudioComponentInstanceDispose(unit);
		return null;
	}
	return unit;
}

dev_prop_u32 :: (dev: AudioObjectID, sel: string, scope: string) -> u32 {
	addr := AudioObjectPropertyAddress.{fourcc(sel), fourcc(scope), 0};
	v: u32;
	sz: u32 = 4;
	if AudioObjectGetPropertyData(dev, *addr, 0, null, *sz, *v) != 0 return 0;
	return v;
}

update_latency :: () {
	if !mac.out_unit return;
	dev: AudioObjectID;
	sz: u32 = 4;
	AudioUnitGetProperty(mac.out_unit, kAudioOutputUnitProperty_CurrentDevice, SCOPE_GLOBAL, 0, *dev, *sz);
	frames := dev_prop_u32(dev, "ltnc", "outp") + dev_prop_u32(dev, "saft", "outp") + dev_prop_u32(dev, "fsiz", "glob");
	rate: float64 = SAMPLE_RATE;
	addr := AudioObjectPropertyAddress.{fourcc("nsrt"), fourcc("glob"), 0};
	rsz: u32 = 8;
	AudioObjectGetPropertyData(dev, *addr, 0, null, *rsz, *rate);
	unit_lat: float64;
	lsz: u32 = 8;
	AudioUnitGetProperty(mac.out_unit, kAudioUnitProperty_Latency, SCOPE_GLOBAL, 0, *unit_lat, *lsz);
	st.latency = frames / max(rate, 1) + unit_lat;
}

cf_string :: (obj: u32, sel: string, allocator: Allocator) -> string {
	a := AudioObjectPropertyAddress.{fourcc(sel), fourcc("glob"), 0};
	ref: *void;
	sz: u32 = size_of(*void);
	if AudioObjectGetPropertyData(obj, *a, 0, null, *sz, *ref) != 0 || !ref return "";
	defer CFRelease(ref);
	buf: [512]u8;
	if !CFStringGetCString(ref, buf.data, buf.count, 0x08000100) return ""; // UTF-8
	return copy_string(to_string(buf.data),, allocator);
}

default_device :: (input: bool) -> u32 {
	a := AudioObjectPropertyAddress.{fourcc(ifx input then "dIn " else "dOut"), fourcc("glob"), 0};
	id: u32;
	sz: u32 = 4;
	AudioObjectGetPropertyData(SYSTEM_OBJECT, *a, 0, null, *sz, *id);
	return id;
}
