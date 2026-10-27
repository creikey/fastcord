// WASAPI shared mode, event driven, f32 stereo 48 kHz (AUTOCONVERTPCM lets the engine
// resample/convert). Capture: separate mono client. Default-device changes are handled by
// re-opening on AUDCLNT_E_DEVICE_INVALIDATED. Not compiled on macOS.
//
// Device selection is not implemented yet (WASAPI endpoints via
// IMMDeviceEnumerator::EnumAudioEndpoints): the default endpoints are used.

#scope_export

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

// No device choice yet: the settings page offers only "Default".
list_devices :: (input: bool, allocator := context.allocator) -> []Device_Info { return .[]; }

selected_device :: (input: bool) -> u32 { return 0; }
select_device :: (input: bool, id: u32) {}
set_voice_processing :: (p: Voice_Processing) {}
apply_device_selection :: () {}

#scope_module

device_init :: () -> bool {
	CoInitializeEx(null, COINIT_MULTITHREADED);
	if CoCreateInstance(*CLSID_MMDeviceEnumerator, null, CLSCTX_ALL, *IID_IMMDeviceEnumerator, *wa.enumerator) < 0 return false;
	return open_stream(*wa.out, false);
}

device_shutdown :: () {
	stop_stream(*wa.out);
	close_stream(*wa.out);
	release(wa.enumerator);
	wa = .{};
	st.running = false;
}

device_start :: () {
	if st.running || !wa.out.client return;
	start_stream(*wa.out);
	st.running = true;
}

device_stop :: () {
	if !st.running return;
	stop_stream(*wa.out);
	st.running = false;
}

device_capture_start :: (voice_processing: bool) -> bool {
	// TODO: voice processing via IAudioClient2::SetClientProperties(AUDIO_STREAM_CATEGORY_Communications)
	if !open_stream(*wa.inp, true) return false;
	start_stream(*wa.inp);
	return true;
}

device_capture_stop :: () {
	stop_stream(*wa.inp);
	close_stream(*wa.inp);
}

#scope_file

#import "Windows";
ole32 :: #system_library "ole32";
CoInitializeEx :: (reserved: *void, coinit: u32) -> HRESULT #foreign ole32;
CoUninitialize :: () #foreign ole32;
CoCreateInstance :: (clsid: *GUID, outer: *void, cls_context: u32, iid: *GUID, out: **void) -> HRESULT #foreign ole32;
SetEvent_ :: (event: HANDLE) -> s32 #foreign kernel32 "SetEvent";
kernel32 :: #system_library "kernel32";
COINIT_MULTITHREADED :: 0;
CLSCTX_ALL :: 0x17;
AUDCLNT_E_DEVICE_INVALIDATED :: cast(HRESULT) 0x88890004;

// COM method i of obj's vtable, called as a C procedure of type T.
com :: inline (obj: *void, i: int, $T: Type) -> T #no_context { return cast(T) (cast(***void) obj).*[i]; }

release :: (obj: *void) #no_context {
	if obj com(obj, 2, #type (*void) -> u32 #c_call)(obj);
}

CLSID_MMDeviceEnumerator := GUID.{0xBCDE0395, 0xE52F, 0x467C, .[0x8E, 0x3D, 0xC4, 0x57, 0x92, 0x91, 0x69, 0x2E]};
IID_IMMDeviceEnumerator := GUID.{0xA95664D2, 0x9614, 0x4F35, .[0xA7, 0x46, 0xDE, 0x8D, 0xB6, 0x36, 0x17, 0xE6]};
IID_IAudioClient := GUID.{0x1CB9AD4C, 0xDBFA, 0x4C32, .[0xB1, 0x78, 0xC2, 0xF5, 0x68, 0xA7, 0x03, 0xB2]};
IID_IAudioRenderClient := GUID.{0xF294ACFC, 0x3146, 0x4483, .[0xA7, 0xBF, 0xAD, 0xDC, 0xA7, 0xC2, 0x60, 0xE2]};
IID_IAudioCaptureClient := GUID.{0xC8ADBD64, 0xE71E, 0x48A0, .[0xA4, 0xDE, 0x18, 0x5C, 0x39, 0x5C, 0xD3, 0x17]};
SUBTYPE_IEEE_FLOAT := GUID.{0x00000003, 0x0000, 0x0010, .[0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71]};

WAVEFORMATEXTENSIBLE :: struct {
	wFormatTag: u16;
	nChannels: u16;
	nSamplesPerSec: u32;
	nAvgBytesPerSec: u32;
	nBlockAlign: u16;
	wBitsPerSample: u16;
	cbSize: u16;
	wValidBits: u16;
	dwChannelMask: u32;
	SubFormat: GUID;
} #no_padding

Stream :: struct {
	client: *void; // IAudioClient
	service: *void; // IAudioRenderClient / IAudioCaptureClient
	event: HANDLE;
	frames: u32;
	thread: Thread;
	thread_started: bool;
	quit: bool; // atomic
	capture: bool;
}

wa: struct {
	enumerator: *void;
	out: Stream;
	inp: Stream;
};

open_stream :: (s: *Stream, capture: bool) -> bool {
	dev: *void;
	// GetDefaultAudioEndpoint(dataFlow: eRender 0 / eCapture 1, role: eConsole 0 / eCommunications 2)
	if com(wa.enumerator, 4, #type (*void, u32, u32, **void) -> HRESULT #c_call)(wa.enumerator, xx ifx capture then 1 else 0, xx ifx capture then 2 else 0, *dev) < 0 return false;
	defer release(dev);
	if com(dev, 3, #type (*void, *GUID, u32, *void, **void) -> HRESULT #c_call)(dev, *IID_IAudioClient, 1, null, *s.client) < 0 return false;
	ch: u16 = xx ifx capture then 1 else CHANNELS;
	f := WAVEFORMATEXTENSIBLE.{
		wFormatTag = 0xFFFE, nChannels = ch, nSamplesPerSec = SAMPLE_RATE,
		nAvgBytesPerSec = SAMPLE_RATE * 4 * cast(u32) ch, nBlockAlign = 4 * ch, wBitsPerSample = 32,
		cbSize = 22, wValidBits = 32, dwChannelMask = xx ifx capture then 4 else 3, SubFormat = SUBTYPE_IEEE_FLOAT
	};
	flags: u32 = 0x40000 | 0x80000000 | 0x08000000; // EVENTCALLBACK | AUTOCONVERTPCM | SRC_DEFAULT_QUALITY
	if com(s.client, 3, #type (*void, u32, u32, s64, s64, *void, *void) -> HRESULT #c_call)(s.client, 0, flags, 100_000, 0, *f, null) < 0 {
		release(s.client);
		s.client = null;
		return false;
	}
	com(s.client, 4, #type (*void, *u32) -> HRESULT #c_call)(s.client, *s.frames);
	s.event = CreateEventW(null, 0, 0, null);
	com(s.client, 13, #type (*void, HANDLE) -> HRESULT #c_call)(s.client, s.event);
	iid := ifx capture then *IID_IAudioCaptureClient else *IID_IAudioRenderClient;
	com(s.client, 14, #type (*void, *GUID, **void) -> HRESULT #c_call)(s.client, iid, *s.service);
	s.capture = capture;
	if !capture {
		lat: s64;
		com(s.client, 5, #type (*void, *s64) -> HRESULT #c_call)(s.client, *lat);
		st.latency = cast(float64) lat / 10_000_000 + cast(float64) s.frames / SAMPLE_RATE;
	}
	return s.service != null;
}

close_stream :: (s: *Stream) {
	if s.client com(s.client, 11, #type (*void) -> HRESULT #c_call)(s.client); // Stop
	release(s.service);
	release(s.client);
	if s.event CloseHandle(s.event);
	s.client, s.service, s.event = null, null, null;
}

stream_thread :: (th: *Thread) -> s64 {
	s := cast(*Stream) th.data;
	CoInitializeEx(null, COINIT_MULTITHREADED);
	defer CoUninitialize();
	scratch: [4096]float32;
	while !atomic_load(*s.quit) {
		WaitForSingleObject(s.event, 200);
		if s.capture {
			while true {
				data: *float32;
				n, flags: u32;
				hr := com(s.service, 3, #type (*void, **float32, *u32, *u32, *u64, *u64) -> HRESULT #c_call)(s.service, *data, *n, *flags, null, null);
				if hr != 0 || n == 0 break;
				if flags & 2 { // SILENT
					m := min(cast(int) n, scratch.count);
					memset(scratch.data, 0, m * size_of(float32));
					ring_write(*st.capture, array_view(scratch, 0, m));
				} else {
					ring_write(*st.capture, .{n, data});
				}
				com(s.service, 4, #type (*void, u32) -> HRESULT #c_call)(s.service, n);
			}
			continue;
		}
		pad: u32;
		hr := com(s.client, 6, #type (*void, *u32) -> HRESULT #c_call)(s.client, *pad);
		if hr == AUDCLNT_E_DEVICE_INVALIDATED {
			// Default device changed / unplugged: reopen on the new default.
			close_stream(s);
			if !open_stream(s, false) return 0;
			com(s.client, 10, #type (*void) -> HRESULT #c_call)(s.client); // Start
			continue;
		}
		avail := s.frames - pad;
		if avail == 0 continue;
		buf: *float32;
		if com(s.service, 3, #type (*void, u32, **float32) -> HRESULT #c_call)(s.service, avail, *buf) < 0 continue;
		mix(.{avail * CHANNELS, buf});
		com(s.service, 4, #type (*void, u32, u32) -> HRESULT #c_call)(s.service, avail, 0);
	}
	return 0;
}

start_stream :: (s: *Stream) {
	com(s.client, 10, #type (*void) -> HRESULT #c_call)(s.client); // Start
	atomic_store(*s.quit, false);
	thread_init(*s.thread, stream_thread);
	s.thread.data = s;
	thread_start(*s.thread);
	s.thread_started = true;
}

stop_stream :: (s: *Stream) {
	if !s.thread_started return;
	atomic_store(*s.quit, true);
	SetEvent_(s.event);
	thread_is_done(*s.thread, -1);
	thread_deinit(*s.thread);
	s.thread_started = false;
	if s.client com(s.client, 11, #type (*void) -> HRESULT #c_call)(s.client); // Stop
}
