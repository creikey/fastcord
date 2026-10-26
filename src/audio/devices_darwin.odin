#+build darwin
package audio

// Device enumeration / selection and voice-processing switches (CoreAudio).
//
// Selection applies to the VoiceProcessingIO unit used while capturing
// (element 1 = input device, element 0 = output device), the way WebRTC's
// macOS VPIO path does it. Outside a capture the output follows the system
// default (DefaultOutput unit); the choice is remembered and re-applied by
// apply_device_selection() after capture_start.

import "core:strings"
import CF "core:sys/darwin/CoreFoundation"

@(private = "file")
Addr :: struct {
	sel, scope, elem: u32,
}

foreign import CA "system:CoreAudio.framework"

@(private = "file", default_calling_convention = "c")
foreign CA {
	@(link_name = "AudioObjectGetPropertyDataSize")
	ca_get_size :: proc(obj: u32, addr: ^Addr, qsize: u32, qdata: rawptr, size: ^u32) -> i32 ---
	@(link_name = "AudioObjectGetPropertyData")
	ca_get :: proc(obj: u32, addr: ^Addr, qsize: u32, qdata: rawptr, size: ^u32, data: rawptr) -> i32 ---
}

@(private = "file")
fcc :: proc(s: string) -> u32 {return u32(s[0]) << 24 | u32(s[1]) << 16 | u32(s[2]) << 8 | u32(s[3])}

Device_Info :: struct {
	id:         u32,
	name:       string,
	uid:        string,
	is_default: bool,
}

Voice_Processing :: struct {
	echo_cancellation:  bool, // VPIO DSP on (off = kAUVoiceIOProperty_BypassVoiceProcessing)
	noise_suppression:  bool, // part of the VPIO DSP on macOS: only honoured together with the DSP
	auto_gain_control:  bool, // kAUVoiceIOProperty_VoiceProcessingEnableAGC
}

@(private = "file")
sel_input, sel_output: u32 // 0 = system default
@(private = "file")
processing := Voice_Processing{true, true, true}

@(private = "file")
cf_string :: proc(obj: u32, sel: string, allocator := context.allocator) -> string {
	a := Addr{fcc(sel), fcc("glob"), 0}
	ref: rawptr
	sz := u32(size_of(rawptr))
	if ca_get(obj, &a, 0, nil, &sz, &ref) != 0 || ref == nil do return ""
	defer CF.CFRelease(CF.TypeRef(ref))
	buf: [512]u8
	if !CF.StringGetCString(CF.String(ref), &buf[0], CF.Index(len(buf)), CF.StringEncoding(0x08000100)) do return ""
	return strings.clone_from_cstring(cstring(&buf[0]), allocator)
}

@(private = "file")
default_device :: proc(input: bool) -> u32 {
	a := Addr{fcc("dIn " if input else "dOut"), fcc("glob"), 0}
	id: u32
	sz: u32 = 4
	ca_get(1, &a, 0, nil, &sz, &id)
	return id
}

// list_devices: devices with input (or output) streams; caller frees with delete_devices.
list_devices :: proc(input: bool, allocator := context.allocator) -> []Device_Info {
	a := Addr{fcc("dev#"), fcc("glob"), 0}
	sz: u32
	if ca_get_size(1, &a, 0, nil, &sz) != 0 || sz == 0 do return nil
	ids := make([]u32, sz / 4, context.temp_allocator)
	if ca_get(1, &a, 0, nil, &sz, raw_data(ids)) != 0 do return nil
	def := default_device(input)
	out := make([dynamic]Device_Info, 0, len(ids), allocator)
	for id in ids {
		sa := Addr{fcc("stm#"), fcc("inpt" if input else "outp"), 0}
		ss: u32
		if ca_get_size(id, &sa, 0, nil, &ss) != 0 || ss == 0 do continue
		append(&out, Device_Info{id = id, name = cf_string(id, "lnam", allocator), uid = cf_string(id, "uid ", allocator), is_default = id == def})
	}
	return out[:]
}

delete_devices :: proc(d: []Device_Info, allocator := context.allocator) {
	for x in d {
		delete(x.name, allocator)
		delete(x.uid, allocator)
	}
	delete(d, allocator)
}

selected_device :: proc(input: bool) -> u32 {return sel_input if input else sel_output}

// select_device: 0 = follow the system default.
select_device :: proc(input: bool, id: u32) {
	if input {
		sel_input = id
	} else {
		sel_output = id
	}
	apply_device_selection()
}

set_voice_processing :: proc(p: Voice_Processing) {
	processing = p
	apply_device_selection()
}

get_voice_processing :: proc() -> Voice_Processing {return processing}

// apply_device_selection re-applies device choice and DSP switches to the
// running VPIO unit (no-op when not capturing).
apply_device_selection :: proc() {
	unit, vpio := _darwin_unit()
	if unit == nil || !vpio do return
	in_dev := sel_input if sel_input != 0 else default_device(true)
	out_dev := sel_output if sel_output != 0 else default_device(false)
	was := st.running
	if was do AudioOutputUnitStop(unit)
	AudioUnitUninitialize(unit)
	AudioUnitSetProperty(unit, 2000 /*CurrentDevice*/, 0, 1, &in_dev, 4)
	AudioUnitSetProperty(unit, 2000, 0, 0, &out_dev, 4)
	bypass: u32 = 0 if (processing.echo_cancellation || processing.noise_suppression) else 1
	AudioUnitSetProperty(unit, 2100 /*BypassVoiceProcessing*/, 0, 0, &bypass, 4)
	agc: u32 = 1 if processing.auto_gain_control else 0
	AudioUnitSetProperty(unit, 2101 /*VoiceProcessingEnableAGC*/, 0, 0, &agc, 4)
	AudioUnitInitialize(unit)
	if was do AudioOutputUnitStart(unit)
}
