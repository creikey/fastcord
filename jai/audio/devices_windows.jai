// Device selection on Windows is not implemented yet (WASAPI endpoints via
// IMMDeviceEnumerator::EnumAudioEndpoints): the default endpoints are used.

Device_Info :: struct {
	id: u32;
	name: string;
	uid: string;
	is_default: bool;
}

Voice_Processing :: struct {
	echo_cancellation: bool;
	noise_suppression: bool;
	auto_gain_control: bool;
}
#scope_file

processing := Voice_Processing.{true, true, true};
#scope_export

list_devices :: (input: bool, allocator := context.allocator) -> []Device_Info {
	out := make_slice(Device_Info, 1, allocator);
	at(*out, 0).* = Device_Info.{id = 0, name = "Default", is_default = true};
	return out;
}

delete_devices :: (d: []Device_Info, allocator := context.allocator) {delete(d, allocator);}
selected_device :: (input: bool) -> u32 {return 0;}
select_device :: (input: bool, id: u32) {}
set_voice_processing :: (p: Voice_Processing) {processing = p;}
get_voice_processing :: () -> Voice_Processing {return processing;}
apply_device_selection :: () {}

