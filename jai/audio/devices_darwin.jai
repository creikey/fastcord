// Device enumeration / selection and voice-processing switches (CoreAudio).
//
// Selection applies to the VoiceProcessingIO unit used while capturing
// (element 1 = input device, element 0 = output device), the way WebRTC's
// macOS VPIO path does it. Outside a capture the output follows the system
// default (DefaultOutput unit); the choice is remembered and re-applied by
// apply_device_selection() after capture_start.



#scope_file

Addr :: struct {
	sel, scope, elem: u32;
}
	ca_get_size :: (obj: u32, addr: *Addr, qsize: u32, qdata: *void, size: *u32) -> s32 #foreign CA "AudioObjectGetPropertyDataSize";
	ca_get :: (obj: u32, addr: *Addr, qsize: u32, qdata: *void, size: *u32, data: *void) -> s32 #foreign CA "AudioObjectGetPropertyData";

fcc :: (s: string) -> u32 {return cast(u32)(s[0]) << 24 | cast(u32)(s[1]) << 16 | cast(u32)(s[2]) << 8 | cast(u32)(s[3]);}
#scope_export

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
#scope_file

sel_input, sel_output: u32;
#scope_export
#scope_file // 0 = system default
// 0 = system default
processing := Voice_Processing.{true, true, true};
#scope_file

cf_string :: (obj: u32, sel: string, allocator := context.allocator) -> string {
	a := Addr.{fcc(sel), fcc("glob"), 0};
	ref: *void;
	sz := cast(u32)(size_of(*void));
	if ca_get(obj, *a, 0, null, *sz, *ref) != 0 || ref == null { return ""; }
	defer CF.CFRelease(CF.TypeRef(ref));
	buf: [512]u8;
	if !CF.StringGetCString(CF.String(ref), *buf[0], CF.Index(len(buf)), CF.StringEncoding(0x08000100)) { return ""; }
	return strings.clone_from_cstring(to_cstring(*buf[0]), allocator);
}

default_device :: (input: bool) -> u32 {
	a := Addr.{fcc(ifx input then "dIn " else "dOut"), fcc("glob"), 0};
	id: u32;
	sz: u32 = 4;
	ca_get(1, *a, 0, null, *sz, *id);
	return id;
}
#scope_export

// list_devices: devices with input (or output) streams; caller frees with delete_devices.
list_devices :: (input: bool, allocator := context.allocator) -> []Device_Info {
	a := Addr.{fcc("dev#"), fcc("glob"), 0};
	sz: u32;
	if ca_get_size(1, *a, 0, null, *sz) != 0 || sz == 0 { return .{}; }
	ids := make_slice(u32, sz / 4, temp);
	if ca_get(1, *a, 0, null, *sz, raw_data(ids)) != 0 { return .{}; }
	def := default_device(input);
	out := make_dynamic(Device_Info, 0, len(ids), allocator);
	for id: ids {
		sa := Addr.{fcc("stm#"), fcc(ifx input then "inpt" else "outp"), 0};
		ss: u32;
		if ca_get_size(id, *sa, 0, null, *ss) != 0 || ss == 0 { continue; }
		append(*out, Device_Info.{id = id, name = cf_string(id, "lnam", allocator), uid = cf_string(id, "uid ", allocator), is_default = id == def});
	}
	return view(out);
}

delete_devices :: (d: []Device_Info, allocator := context.allocator) {
	for x: d {
		delete(x.name, allocator);
		delete(x.uid, allocator);
	}
	delete(d, allocator);
}

selected_device :: (input: bool) -> u32 {return ifx input then sel_input else sel_output;}

// select_device: 0 = follow the system default.
select_device :: (input: bool, id: u32) {
	if input {
		sel_input = id;
	} else {
		sel_output = id;
	}
	apply_device_selection();
}

set_voice_processing :: (p: Voice_Processing) {
	processing = p;
	apply_device_selection();
}

get_voice_processing :: () -> Voice_Processing {return processing;}

// apply_device_selection re-applies device choice and DSP switches to the
// running VPIO unit (no-op when not capturing).
apply_device_selection :: () {
	unit, vpio := _darwin_unit();
	if unit == null || !vpio { return; }
	in_dev := ifx sel_input != 0 then sel_input else default_device(true);
	out_dev := ifx sel_output != 0 then sel_output else default_device(false);
	was := st.running;
	if was { AudioOutputUnitStop(unit); }
	AudioUnitUninitialize(unit);
	AudioUnitSetProperty(unit, 2000, 0, 1, *in_dev, 4);
	AudioUnitSetProperty(unit, 2000, 0, 0, *out_dev, 4);
	bypass: u32 = ifx (processing.echo_cancellation || processing.noise_suppression) then 0 else 1;
	AudioUnitSetProperty(unit, 2100, 0, 0, *bypass, 4);
	agc: u32 = ifx processing.auto_gain_control then 1 else 0;
	AudioUnitSetProperty(unit, 2101, 0, 0, *agc, 4);
	AudioUnitInitialize(unit);
	if was { AudioOutputUnitStart(unit); }
}

