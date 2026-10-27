// CoreAudio: AUHAL DefaultOutput unit (follows the system default device
// automatically) for output; VoiceProcessingIO for capture + echo cancellation.



OSStatus :: s32;
AudioUnit :: *void;
AudioObjectID :: u32;

AudioComponentDescription :: struct {
	componentType, componentSubType, componentManufacturer, componentFlags, componentFlagsMask: u32;
}

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

AURenderCallback :: (ref: *void, flags: *u32, ts: *void, bus: u32, frames: u32, data: *AudioBufferList) -> OSStatus #c_call;

AURenderCallbackStruct :: struct {
	inputProc: AURenderCallback;
	inputProcRefCon: *void;
}

AudioObjectPropertyAddress :: struct {
	mSelector, mScope, mElement: u32;
}
#scope_file

AudioObjectPropertyListenerProc :: (obj: AudioObjectID, n: u32, addrs: *AudioObjectPropertyAddress, user: *void) -> OSStatus #c_call;
#scope_export
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
#scope_file
	AudioObjectGetPropertyData :: (obj: AudioObjectID, addr: *AudioObjectPropertyAddress, qsize: u32, qdata: *void, size: *u32, data: *void) -> OSStatus #foreign CoreAudio;
	AudioObjectAddPropertyListener :: (obj: AudioObjectID, addr: *AudioObjectPropertyAddress, listener: AudioObjectPropertyListenerProc, user: *void) -> OSStatus #foreign CoreAudio;
#scope_export

fourcc :: inline (s: string) -> u32 #no_context {
	return cast(u32)(s[0]) << 24 | cast(u32)(s[1]) << 16 | cast(u32)(s[2]) << 8 | cast(u32)(s[3]);
};

kAudioFormatLinearPCM :: 0x6c70636d; // 'lpcm'
kAudioFormatFlagIsFloat :: 1;
kAudioFormatFlagIsSignedInteger :: 4;
kAudioFormatFlagIsPacked :: 8;
kAudioFormatFlagIsNonInterleaved :: 32;
#scope_file

kAudioUnitProperty_StreamFormat :: 8;
kAudioUnitProperty_SetRenderCallback :: 23;
kAudioUnitProperty_MaximumFramesPerSlice :: 14;
kAudioUnitProperty_Latency :: 12;
kAudioOutputUnitProperty_CurrentDevice :: 2000;
kAudioOutputUnitProperty_EnableIO :: 2003;
kAudioOutputUnitProperty_SetInputCallback :: 2005;
SCOPE_GLOBAL :: 0;
SCOPE_INPUT :: 1;
SCOPE_OUTPUT :: 2;

Mac :: struct {
	out_unit: AudioUnit; // DefaultOutput or VPIO while capturing
	vpio: bool;
	in_buf: []float32;
}

mac: Mac;

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

render_cb :: (ref: *void, flags: *u32, ts: *void, bus: u32, frames: u32, data: *AudioBufferList) -> OSStatus #c_call {
	sync.atomic_add(*st.callbacks, 1);
	buf := data.mBuffers[0];
	out := sub(cast(*float32)(buf.mData), 0, min(cast(int)(frames) * CHANNELS, cast(int)(buf.mDataByteSize) / 4));
	mix(out);
	return 0;
}

input_cb :: (ref: *void, flags: *u32, ts: *void, bus: u32, frames: u32, data: *AudioBufferList) -> OSStatus #c_call {
	n := min(cast(int)(frames), len(mac.in_buf));
	abl := AudioBufferList.{mNumberBuffers = 1};
	abl.mBuffers[0] = .{mNumberChannels = 1, mDataByteSize = cast(u32)(n * 4), mData = raw_data(mac.in_buf)};
	fl: u32 = 0;
	if AudioUnitRender(mac.out_unit, *fl, ts, 1, cast(u32)(n), *abl) == 0 {
		ring_write(*st.capture, sub(mac.in_buf, 0, n));
	}
	return 0;
}

make_unit :: (subtype: string, capture: bool) -> AudioUnit {
	desc := AudioComponentDescription.{fourcc("auou"), fourcc(subtype), fourcc("appl"), 0, 0};
	comp := AudioComponentFindNext(null, *desc);
	if comp == null { return .{}; }
	unit: AudioUnit;
	if AudioComponentInstanceNew(comp, *unit) != 0 { return .{}; }
	if capture {
		one: u32 = 1;
		AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, SCOPE_INPUT, 1, *one, 4);
		mono := stereo_f32(1);
		AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, SCOPE_OUTPUT, 1, *mono, size_of(mono));
		icb := AURenderCallbackStruct.{input_cb, null};
		AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, SCOPE_GLOBAL, 0, *icb, size_of(icb));
	}
	f := stereo_f32(CHANNELS);
	if AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, SCOPE_INPUT, 0, *f, size_of(f)) != 0 {
		AudioComponentInstanceDispose(unit);
		return .{};
	}
	maxf: u32 = 4096;
	AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, SCOPE_GLOBAL, 0, *maxf, 4);
	// Small IO buffer for low latency (per-client on macOS; doesn't affect other apps).
	bs: u32 = 256;
	AudioUnitSetProperty(unit, fourcc("fsiz"), SCOPE_GLOBAL, 0, *bs, 4);
	cb := AURenderCallbackStruct.{render_cb, null};
	AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, SCOPE_INPUT, 0, *cb, size_of(cb));
	if AudioUnitInitialize(unit) != 0 {
		AudioComponentInstanceDispose(unit);
		return .{};
	}
	return unit;
}

dev_prop_u32 :: (dev: AudioObjectID, sel: string, scope: string) -> u32 {
	addr := AudioObjectPropertyAddress.{fourcc(sel), fourcc(scope), 0};
	v: u32;
	sz: u32 = 4;
	if AudioObjectGetPropertyData(dev, *addr, 0, null, *sz, *v) != 0 { return 0; }
	return v;
}

update_latency :: () {
	if mac.out_unit == null { return; }
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
	st.latency = cast(float64)(frames) / max(rate, 1) + unit_lat;
}

default_device_changed :: (obj: AudioObjectID, n: u32, addrs: *AudioObjectPropertyAddress, user: *void) -> OSStatus #c_call {
	// DefaultOutput/VPIO units re-route themselves; only the latency estimate changes.
	context = st.ctx;
	update_latency();
	return 0;
}
#scope_module

_device_init :: () -> bool {
	mac.out_unit = make_unit("def ", false);
	if mac.out_unit == null { return false; }
	update_latency();
	addr := AudioObjectPropertyAddress.{fourcc("dOut"), fourcc("glob"), 0};
	AudioObjectAddPropertyListener(1, *addr, default_device_changed, null);
	return true;
}

_device_shutdown :: () {
	if mac.out_unit != null {
		AudioOutputUnitStop(mac.out_unit);
		AudioUnitUninitialize(mac.out_unit);
		AudioComponentInstanceDispose(mac.out_unit);
	}
	delete(mac.in_buf);
	mac = .{};
	st.running = false;
}

_device_start :: () {
	if mac.out_unit == null || st.running { return; }
	if AudioOutputUnitStart(mac.out_unit) == 0 { st.running = true; }
}

_device_stop :: () {
	if mac.out_unit == null || !st.running { return; }
	AudioOutputUnitStop(mac.out_unit);
	st.running = false;
}

_capture_start :: (voice_processing: bool) -> bool {
	if mac.in_buf == null { mac.in_buf = make_slice(float32, 8192); }
	was_running := st.running;
	_device_stop();
	// Always VPIO (one unit for in+out, follows default devices); without voice
	// processing we just bypass the DSP.
	unit := make_unit("vpio", true);
	if unit != null && !voice_processing {
		bypass: u32 = 1;
		AudioUnitSetProperty(unit, 2100, SCOPE_GLOBAL, 0, *bypass, 4);
	}
	if unit == null {
		if was_running { _device_start(); }
		return false;
	}
	AudioUnitUninitialize(mac.out_unit);
	AudioComponentInstanceDispose(mac.out_unit);
	mac.out_unit = unit;
	mac.vpio = true;
	update_latency();
	_device_start();
	return st.running;
}

_capture_stop :: () {
	_device_stop();
	AudioUnitUninitialize(mac.out_unit);
	AudioComponentInstanceDispose(mac.out_unit);
	mac.out_unit = make_unit("def ", false);
	mac.vpio = false;
	update_latency();
}

// Hook for devices_darwin.odin: the unit currently doing I/O (VPIO while capturing).
_darwin_unit :: () -> AudioUnit, bool {
	unit: AudioUnit;
	vpio: bool;return mac.out_unit, mac.vpio;}
#scope_export

