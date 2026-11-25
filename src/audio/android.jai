// Android: no audio yet (TODO.md, Android step 9: AAudio). device_init fails, so the app runs silent, as
// Linux does without libasound.

#scope_export

Device_Info :: struct {
	id: u32;
	name: string;
	uid: string;
	is_default: bool;
}

list_devices :: (input: bool, allocator := context.allocator) -> []Device_Info { return .[]; }
selected_device :: (input: bool) -> u32 { return 0; }
select_device :: (input: bool, id: u32) {}
device_rate_changed :: () {}
apply_device_selection :: () {}

#scope_module

device_init :: () -> bool { return false; }
device_shutdown :: () {}
device_start :: () {}
device_stop :: () {}
device_capture_start :: () -> bool { return false; }
device_capture_stop :: () {}
