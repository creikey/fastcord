// CoreAudio: AUHAL DefaultOutput unit (follows the system default device automatically) for output;
// VoiceProcessingIO for capture + echo cancellation.
//
// Device selection applies to the VoiceProcessingIO unit used while capturing (element 1 = input
// device, element 0 = output device), the way WebRTC's macOS VPIO path does it. Outside a capture
// the output follows the system default (DefaultOutput unit); the choice is remembered and
// re-applied by apply_device_selection(). A capture without voice processing (the settings mic
// meter, or a call with every DSP switch off) is a separate input-only AUHAL unit and leaves
// output alone: VPIO with kAUVoiceIOProperty_BypassVoiceProcessing delivers the MacBook mic about
// 27 dB quieter than AUHAL does (measured), so bypass is only the fallback for input devices not
// at 48 kHz, which AUHAL would not resample. AGC alone doesn't start VPIO: its echo canceller comes
// along and, half duplex, zeroed the mic for seconds while others talked (seen live), so AUHAL
// capture gets the voice module's software AGC instead (software_agc).

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

Voice_Processing :: struct {
	echo_cancellation: bool; // VPIO DSP on (off = kAUVoiceIOProperty_BypassVoiceProcessing)
	noise_suppression: bool; // part of the VPIO DSP on macOS: only honoured together with the DSP
	auto_gain_control: bool; // kAUVoiceIOProperty_VoiceProcessingEnableAGC
}

// list_devices: devices with input (or output) streams. Enumerating asks
// coreaudiod about every device (24 devices: ~3 ms for the voice page's four
// lists per frame, 78 ms cold), so the lists are kept and HAL listeners mark
// them stale when the devices or the defaults change.
list_devices :: (input: bool, allocator := context.allocator) -> []Device_Info {
	if !dev.listening {
		dev.listening = true;
		for sel: string.["dev#", "dIn ", "dOut"] {
			a := AudioObjectPropertyAddress.{fourcc(sel), fourcc("glob"), 0};
			AudioObjectAddPropertyListener(SYSTEM_OBJECT, *a, devices_changed, null);
		}
	}
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

// software_agc: the call's capture runs without VPIO but AGC is on, so the caller applies it.
software_agc :: () -> bool { return mac.call && mac.in_unit != null && processing.auto_gain_control; }

set_voice_processing :: (p: Voice_Processing) {
	processing = p;
	apply_device_selection();
}

// apply_device_selection re-applies device choice and DSP switches to the
// running capture (no-op when not capturing).
apply_device_selection :: () {
	locks.guard(*st.device_mu);
	apply_selection();
}

#scope_module

device_init :: () -> bool {
	mac.out_unit = make_unit("def ", false);
	if !mac.out_unit return false;
	update_latency();
	addr := AudioObjectPropertyAddress.{fourcc("dOut"), fourcc("glob"), 0};
	AudioObjectAddPropertyListener(SYSTEM_OBJECT, *addr, default_device_changed, null);
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

// device_capture_start: voice_processing marks a call's capture, which follows the DSP switches.
device_capture_start :: (voice_processing: bool) -> bool {
	if !mac.in_buf.count mac.in_buf = NewArray(8192, float32);
	mac.call = voice_processing;
	if !voice_processing mac.in_unit = open_input_unit();
	else apply_selection();
	return mac.in_unit != null || (mac.vpio && st.running);
}

device_capture_stop :: () {
	if mac.in_unit close_input_unit();
	if mac.vpio use_vpio(false);
	mac.call = false;
}

device_rate_changed :: () {
	if mac.in_unit && device_rate(mac.rate_dev) != mac.in_rate apply_selection();
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
AudioObjectSetPropertyData :: (obj: AudioObjectID, addr: *AudioObjectPropertyAddress, qsize: u32, qdata: *void, size: u32, data: *void) -> OSStatus #foreign CoreAudio;
AudioObjectGetPropertyData :: (obj: AudioObjectID, addr: *AudioObjectPropertyAddress, qsize: u32, qdata: *void, size: *u32, data: *void) -> OSStatus #foreign CoreAudio;
AudioObjectRemovePropertyListener :: (obj: AudioObjectID, addr: *AudioObjectPropertyAddress, listener: (obj: AudioObjectID, n: u32, addrs: *AudioObjectPropertyAddress, user: *void) -> OSStatus #c_call, user: *void) -> OSStatus #foreign CoreAudio;
AudioObjectAddPropertyListener :: (obj: AudioObjectID, addr: *AudioObjectPropertyAddress, listener: (obj: AudioObjectID, n: u32, addrs: *AudioObjectPropertyAddress, user: *void) -> OSStatus #c_call, user: *void) -> OSStatus #foreign CoreAudio;
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
kAUVoiceIOProperty_BypassVoiceProcessing :: 2100;
kAUVoiceIOProperty_VoiceProcessingEnableAGC :: 2101;
kAUVoiceIOProperty_OtherAudioDuckingConfiguration :: 2108;
Ducking_Config :: struct { advanced: bool; level: u32; } // AUVoiceIOOtherAudioDuckingConfiguration
SCOPE_GLOBAL :: 0;
SCOPE_INPUT :: 1;
SCOPE_OUTPUT :: 2;

mac: struct {
	out_unit: AudioUnit; // DefaultOutput or VPIO while capturing
	in_unit: AudioUnit; // input-only AUHAL while capturing without voice processing
	vpio: bool;
	in_rate: float64; // the input-only unit's device rate when opened
	rate_dev: u32; // the device whose rate we listen to
	call: bool; // a call's capture: VPIO or AUHAL by the DSP switches
	in_buf: []float32;
};

sel_input, sel_output: u32; // 0 = system default
processing := Voice_Processing.{true, true, true};

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
		unit := ifx mac.in_unit then mac.in_unit else mac.out_unit;
		if AudioUnitRender(unit, *fl, ts, 1, cast(u32) n, *abl) == 0 ring_write(*st.capture, array_view(mac.in_buf, 0, n));
	}
	return 0;
}

dev: struct {
	lists: [2][..]Device_Info; // [output, input], heap
	stale := true; // written by devices_changed on a HAL thread
	listening: bool;
};

devices_changed :: (obj: AudioObjectID, n: u32, addrs: *AudioObjectPropertyAddress, user: *void) -> OSStatus #c_call {
	dev.stale = true;
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
		// VPIO's private aggregate of the devices it runs on; a device can also be listed twice
		// while a Bluetooth headset switches profile
		if begins_with(uid, "VPAUAggregateAudioDevice") || array_find_uid(out.*, uid) continue;
		array_add(out, .{id = id, name = cf_string(id, "lnam", context.allocator), uid = copy_string(uid), is_default = id == def});
	}
}

array_find_uid :: (devs: []Device_Info, uid: string) -> bool {
	for devs if it.uid == uid return true;
	return false;
}

// open_input_unit: a started input-only AUHAL unit on the selected input device, no DSP. AUHAL
// doesn't resample input (TN2091), so samples come at the device's rate; fine for a level meter.
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
	// AUHAL doesn't follow a rate change: update() reopens the unit, at the new rate or with VPIO
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

apply_selection :: () {
	if !mac.call {
		if mac.in_unit {
			close_input_unit();
			mac.in_unit = open_input_unit();
		}
		return;
	}
	in_dev := ifx sel_input != 0 then sel_input else default_device(true);
	out_dev := ifx sel_output != 0 then sel_output else default_device(false);
	dsp := processing.echo_cancellation || processing.noise_suppression;
	if mac.in_unit close_input_unit();
	if !dsp && device_rate(in_dev) == SAMPLE_RATE {
		if mac.vpio use_vpio(false);
		mac.in_unit = open_input_unit();
		return;
	}
	// VPIO: one unit for in+out, so the canceller hears the output
	if !mac.vpio && !use_vpio(true) return;
	unit := mac.out_unit;
	device_stop();
	AudioUnitUninitialize(unit);
	AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, SCOPE_GLOBAL, 1, *in_dev, 4);
	AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, SCOPE_GLOBAL, 0, *out_dev, 4);
	// echo cancellation and noise suppression can't be switched apart, and AGC needs the DSP running
	// (bypass here is only the fallback for an input not at 48 kHz)
	bypass: u32 = xx !dsp;
	AudioUnitSetProperty(unit, kAUVoiceIOProperty_BypassVoiceProcessing, SCOPE_GLOBAL, 0, *bypass, 4);
	agc: u32 = xx processing.auto_gain_control;
	AudioUnitSetProperty(unit, kAUVoiceIOProperty_VoiceProcessingEnableAGC, SCOPE_GLOBAL, 0, *agc, 4);
	// VPIO ducks every other app's audio while it runs; keep that to the minimum, as WebRTC does
	// (macOS 14+; ignored before)
	duck := Ducking_Config.{advanced = false, level = 10}; // kAUVoiceIOOtherAudioDuckingLevelMin
	AudioUnitSetProperty(unit, kAUVoiceIOProperty_OtherAudioDuckingConfiguration, SCOPE_GLOBAL, 0, *duck, size_of(Ducking_Config));
	// Left alone, VPIO runs the devices at 4096-frame buffers: the mic arrives in 85 ms bursts
	// (measured on a MacBook Pro). 10 ms, as WebRTC asks for; per process, other apps keep theirs.
	for dev: u32.[in_dev, out_dev] {
		a := AudioObjectPropertyAddress.{fourcc("fsiz"), fourcc("glob"), 0};
		frames: u32 = SAMPLE_RATE / 100;
		AudioObjectSetPropertyData(dev, *a, 0, null, 4, *frames);
	}
	AudioUnitInitialize(unit);
	update_latency();
	device_start();
}

// use_vpio swaps the output unit between VPIO (started) and DefaultOutput (started on demand).
use_vpio :: (on: bool) -> bool {
	unit := make_unit(ifx on then "vpio" else "def ", on);
	if !unit return false;
	device_stop();
	AudioUnitUninitialize(mac.out_unit);
	AudioComponentInstanceDispose(mac.out_unit);
	mac.out_unit = unit;
	mac.vpio = on;
	update_latency();
	return true;
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
}

default_device_changed :: (obj: AudioObjectID, n: u32, addrs: *AudioObjectPropertyAddress, user: *void) -> OSStatus #c_call {
	// DefaultOutput/VPIO units re-route themselves; only the latency estimate changes.
	push_context st.ctx { update_latency(); }
	return 0;
}

make_unit :: (subtype: string, capture: bool) -> AudioUnit {
	desc := AudioComponentDescription.{fourcc("auou"), fourcc(subtype), fourcc("appl"), 0, 0};
	comp := AudioComponentFindNext(null, *desc);
	if !comp return null;
	unit: AudioUnit;
	if AudioComponentInstanceNew(comp, *unit) != 0 return null;
	if capture {
		one: u32 = 1;
		AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, SCOPE_INPUT, 1, *one, 4);
		mono := stereo_f32(1);
		AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, SCOPE_OUTPUT, 1, *mono, size_of(type_of(mono)));
		icb := AURenderCallbackStruct.{input_cb, null};
		AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, SCOPE_GLOBAL, 0, *icb, size_of(type_of(icb)));
	}
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
