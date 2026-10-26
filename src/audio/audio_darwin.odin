#+build darwin
package audio

// CoreAudio: AUHAL DefaultOutput unit (follows the system default device
// automatically) for output; VoiceProcessingIO for capture + echo cancellation.

import "core:sync"

foreign import AudioToolbox "system:AudioToolbox.framework"
foreign import CoreAudio "system:CoreAudio.framework"

OSStatus :: i32
AudioUnit :: rawptr
AudioObjectID :: u32

AudioComponentDescription :: struct {
	componentType, componentSubType, componentManufacturer, componentFlags, componentFlagsMask: u32,
}

AudioStreamBasicDescription :: struct {
	mSampleRate:       f64,
	mFormatID:         u32,
	mFormatFlags:      u32,
	mBytesPerPacket:   u32,
	mFramesPerPacket:  u32,
	mBytesPerFrame:    u32,
	mChannelsPerFrame: u32,
	mBitsPerChannel:   u32,
	mReserved:         u32,
}

AudioBuffer :: struct {
	mNumberChannels: u32,
	mDataByteSize:   u32,
	mData:           rawptr,
}

AudioBufferList :: struct {
	mNumberBuffers: u32,
	mBuffers:       [1]AudioBuffer,
}

AURenderCallback :: #type proc "c" (ref: rawptr, flags: ^u32, ts: rawptr, bus: u32, frames: u32, data: ^AudioBufferList) -> OSStatus

AURenderCallbackStruct :: struct {
	inputProc:       AURenderCallback,
	inputProcRefCon: rawptr,
}

AudioObjectPropertyAddress :: struct {
	mSelector, mScope, mElement: u32,
}

@(private = "file")
AudioObjectPropertyListenerProc :: #type proc "c" (obj: AudioObjectID, n: u32, addrs: [^]AudioObjectPropertyAddress, user: rawptr) -> OSStatus

@(default_calling_convention = "c")
foreign AudioToolbox {
	AudioComponentFindNext :: proc(comp: rawptr, desc: ^AudioComponentDescription) -> rawptr ---
	AudioComponentInstanceNew :: proc(comp: rawptr, out: ^AudioUnit) -> OSStatus ---
	AudioComponentInstanceDispose :: proc(unit: AudioUnit) -> OSStatus ---
	AudioUnitInitialize :: proc(unit: AudioUnit) -> OSStatus ---
	AudioUnitUninitialize :: proc(unit: AudioUnit) -> OSStatus ---
	AudioUnitSetProperty :: proc(unit: AudioUnit, id, scope, element: u32, data: rawptr, size: u32) -> OSStatus ---
	AudioUnitGetProperty :: proc(unit: AudioUnit, id, scope, element: u32, data: rawptr, size: ^u32) -> OSStatus ---
	AudioUnitRender :: proc(unit: AudioUnit, flags: ^u32, ts: rawptr, bus: u32, frames: u32, data: ^AudioBufferList) -> OSStatus ---
	AudioOutputUnitStart :: proc(unit: AudioUnit) -> OSStatus ---
	AudioOutputUnitStop :: proc(unit: AudioUnit) -> OSStatus ---
}

@(private = "file", default_calling_convention = "c")
foreign CoreAudio {
	AudioObjectGetPropertyData :: proc(obj: AudioObjectID, addr: ^AudioObjectPropertyAddress, qsize: u32, qdata: rawptr, size: ^u32, data: rawptr) -> OSStatus ---
	AudioObjectAddPropertyListener :: proc(obj: AudioObjectID, addr: ^AudioObjectPropertyAddress, listener: AudioObjectPropertyListenerProc, user: rawptr) -> OSStatus ---
}

fourcc :: #force_inline proc "contextless" (s: string) -> u32 {
	return u32(s[0]) << 24 | u32(s[1]) << 16 | u32(s[2]) << 8 | u32(s[3])
}

kAudioFormatLinearPCM :: 0x6c70636d // 'lpcm'
kAudioFormatFlagIsFloat :: 1
kAudioFormatFlagIsSignedInteger :: 4
kAudioFormatFlagIsPacked :: 8
kAudioFormatFlagIsNonInterleaved :: 32

@(private = "file") kAudioUnitProperty_StreamFormat :: 8
@(private = "file") kAudioUnitProperty_SetRenderCallback :: 23
@(private = "file") kAudioUnitProperty_MaximumFramesPerSlice :: 14
@(private = "file") kAudioUnitProperty_Latency :: 12
@(private = "file") kAudioOutputUnitProperty_CurrentDevice :: 2000
@(private = "file") kAudioOutputUnitProperty_EnableIO :: 2003
@(private = "file") kAudioOutputUnitProperty_SetInputCallback :: 2005
@(private = "file") SCOPE_GLOBAL :: 0
@(private = "file") SCOPE_INPUT :: 1
@(private = "file") SCOPE_OUTPUT :: 2

@(private = "file")
Mac :: struct {
	out_unit:   AudioUnit, // DefaultOutput or VPIO while capturing
	vpio:       bool,
	in_buf:     []f32,
}

@(private = "file")
mac: Mac

@(private = "file")
stereo_f32 :: proc(ch: u32) -> AudioStreamBasicDescription {
	return {
		mSampleRate = SAMPLE_RATE,
		mFormatID = kAudioFormatLinearPCM,
		mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
		mBytesPerPacket = 4 * ch,
		mFramesPerPacket = 1,
		mBytesPerFrame = 4 * ch,
		mChannelsPerFrame = ch,
		mBitsPerChannel = 32,
	}
}

@(private = "file")
render_cb :: proc "c" (ref: rawptr, flags: ^u32, ts: rawptr, bus: u32, frames: u32, data: ^AudioBufferList) -> OSStatus {
	sync.atomic_add(&st.callbacks, 1)
	buf := data.mBuffers[0]
	out := ([^]f32)(buf.mData)[:min(int(frames) * CHANNELS, int(buf.mDataByteSize) / 4)]
	mix(out)
	return 0
}

@(private = "file")
input_cb :: proc "c" (ref: rawptr, flags: ^u32, ts: rawptr, bus: u32, frames: u32, data: ^AudioBufferList) -> OSStatus {
	n := min(int(frames), len(mac.in_buf))
	abl := AudioBufferList{mNumberBuffers = 1}
	abl.mBuffers[0] = {mNumberChannels = 1, mDataByteSize = u32(n * 4), mData = raw_data(mac.in_buf)}
	fl: u32 = 0
	if AudioUnitRender(mac.out_unit, &fl, ts, 1, u32(n), &abl) == 0 {
		ring_write(&st.capture, mac.in_buf[:n])
	}
	return 0
}

@(private = "file")
make_unit :: proc(subtype: string, capture: bool) -> AudioUnit {
	desc := AudioComponentDescription{fourcc("auou"), fourcc(subtype), fourcc("appl"), 0, 0}
	comp := AudioComponentFindNext(nil, &desc)
	if comp == nil do return nil
	unit: AudioUnit
	if AudioComponentInstanceNew(comp, &unit) != 0 do return nil
	if capture {
		one: u32 = 1
		AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, SCOPE_INPUT, 1, &one, 4)
		mono := stereo_f32(1)
		AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, SCOPE_OUTPUT, 1, &mono, size_of(mono))
		icb := AURenderCallbackStruct{input_cb, nil}
		AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, SCOPE_GLOBAL, 0, &icb, size_of(icb))
	}
	f := stereo_f32(CHANNELS)
	if AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, SCOPE_INPUT, 0, &f, size_of(f)) != 0 {
		AudioComponentInstanceDispose(unit)
		return nil
	}
	maxf: u32 = 4096
	AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, SCOPE_GLOBAL, 0, &maxf, 4)
	// Small IO buffer for low latency (per-client on macOS; doesn't affect other apps).
	bs: u32 = 256
	AudioUnitSetProperty(unit, fourcc("fsiz"), SCOPE_GLOBAL, 0, &bs, 4)
	cb := AURenderCallbackStruct{render_cb, nil}
	AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, SCOPE_INPUT, 0, &cb, size_of(cb))
	if AudioUnitInitialize(unit) != 0 {
		AudioComponentInstanceDispose(unit)
		return nil
	}
	return unit
}

@(private = "file")
dev_prop_u32 :: proc(dev: AudioObjectID, sel: string, scope: string) -> u32 {
	addr := AudioObjectPropertyAddress{fourcc(sel), fourcc(scope), 0}
	v: u32
	sz: u32 = 4
	if AudioObjectGetPropertyData(dev, &addr, 0, nil, &sz, &v) != 0 do return 0
	return v
}

@(private = "file")
update_latency :: proc() {
	if mac.out_unit == nil do return
	dev: AudioObjectID
	sz: u32 = 4
	AudioUnitGetProperty(mac.out_unit, kAudioOutputUnitProperty_CurrentDevice, SCOPE_GLOBAL, 0, &dev, &sz)
	frames := dev_prop_u32(dev, "ltnc", "outp") + dev_prop_u32(dev, "saft", "outp") + dev_prop_u32(dev, "fsiz", "glob")
	rate: f64 = SAMPLE_RATE
	addr := AudioObjectPropertyAddress{fourcc("nsrt"), fourcc("glob"), 0}
	rsz: u32 = 8
	AudioObjectGetPropertyData(dev, &addr, 0, nil, &rsz, &rate)
	unit_lat: f64
	lsz: u32 = 8
	AudioUnitGetProperty(mac.out_unit, kAudioUnitProperty_Latency, SCOPE_GLOBAL, 0, &unit_lat, &lsz)
	st.latency = f64(frames) / max(rate, 1) + unit_lat
}

@(private = "file")
default_device_changed :: proc "c" (obj: AudioObjectID, n: u32, addrs: [^]AudioObjectPropertyAddress, user: rawptr) -> OSStatus {
	// DefaultOutput/VPIO units re-route themselves; only the latency estimate changes.
	context = st.ctx
	update_latency()
	return 0
}

@(private)
_device_init :: proc() -> bool {
	mac.out_unit = make_unit("def ", false)
	if mac.out_unit == nil do return false
	update_latency()
	addr := AudioObjectPropertyAddress{fourcc("dOut"), fourcc("glob"), 0}
	AudioObjectAddPropertyListener(1 /*kAudioObjectSystemObject*/, &addr, default_device_changed, nil)
	return true
}

@(private)
_device_shutdown :: proc() {
	if mac.out_unit != nil {
		AudioOutputUnitStop(mac.out_unit)
		AudioUnitUninitialize(mac.out_unit)
		AudioComponentInstanceDispose(mac.out_unit)
	}
	delete(mac.in_buf)
	mac = {}
	st.running = false
}

@(private)
_device_start :: proc() {
	if mac.out_unit == nil || st.running do return
	if AudioOutputUnitStart(mac.out_unit) == 0 do st.running = true
}

@(private)
_device_stop :: proc() {
	if mac.out_unit == nil || !st.running do return
	AudioOutputUnitStop(mac.out_unit)
	st.running = false
}

@(private)
_capture_start :: proc(voice_processing: bool) -> bool {
	if mac.in_buf == nil do mac.in_buf = make([]f32, 8192)
	was_running := st.running
	_device_stop()
	// Always VPIO (one unit for in+out, follows default devices); without voice
	// processing we just bypass the DSP.
	unit := make_unit("vpio", true)
	if unit != nil && !voice_processing {
		bypass: u32 = 1
		AudioUnitSetProperty(unit, 2100 /*kAUVoiceIOProperty_BypassVoiceProcessing*/, SCOPE_GLOBAL, 0, &bypass, 4)
	}
	if unit == nil {
		if was_running do _device_start()
		return false
	}
	AudioUnitUninitialize(mac.out_unit)
	AudioComponentInstanceDispose(mac.out_unit)
	mac.out_unit = unit
	mac.vpio = true
	update_latency()
	_device_start()
	return st.running
}

@(private)
_capture_stop :: proc() {
	_device_stop()
	AudioUnitUninitialize(mac.out_unit)
	AudioComponentInstanceDispose(mac.out_unit)
	mac.out_unit = make_unit("def ", false)
	mac.vpio = false
	update_latency()
}

// Hook for devices_darwin.odin: the unit currently doing I/O (VPIO while capturing).
@(private)
_darwin_unit :: proc() -> (unit: AudioUnit, vpio: bool) {return mac.out_unit, mac.vpio}
