// WASAPI shared mode, event driven, f32 stereo 48 kHz (AUTOCONVERTPCM lets the
// engine resample/convert). Capture: separate mono client. Default-device
// changes are handled by re-opening on AUDCLNT_E_DEVICE_INVALIDATED.
// Compile-verified only.




#scope_file

vt :: inline (obj: *void, idx: int) -> *void #no_context {return cast(***void)(obj).*[idx];};

release :: (obj: *void) #no_context {
	if obj != null { (cast((*void) -> u32 #c_call)vt(obj, 2))(obj); }
}

CLSID_MMDeviceEnumerator := win.GUID.{0xBCDE0395, 0xE52F, 0x467C, .{0x8E, 0x3D, 0xC4, 0x57, 0x92, 0x91, 0x69, 0x2E}};
IID_IMMDeviceEnumerator := win.GUID.{0xA95664D2, 0x9614, 0x4F35, .{0xA7, 0x46, 0xDE, 0x8D, 0xB6, 0x36, 0x17, 0xE6}};
IID_IAudioClient := win.GUID.{0x1CB9AD4C, 0xDBFA, 0x4C32, .{0xB1, 0x78, 0xC2, 0xF5, 0x68, 0xA7, 0x03, 0xB2}};
IID_IAudioRenderClient := win.GUID.{0xF294ACFC, 0x3146, 0x4483, .{0xA7, 0xBF, 0xAD, 0xDC, 0xA7, 0xC2, 0x60, 0xE2}};
IID_IAudioCaptureClient := win.GUID.{0xC8ADBD64, 0xE71E, 0x48A0, .{0xA4, 0xDE, 0x18, 0x5C, 0x39, 0x5C, 0xD3, 0x17}};
SUBTYPE_IEEE_FLOAT := win.GUID.{0x00000003, 0x0000, 0x0010, .{0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71}};

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
	SubFormat: win.GUID;
} #no_padding;

AUDCLNT_E_DEVICE_INVALIDATED :: cast(win.HRESULT)(-2004287484);
#scope_export
#scope_file // 0x88890004

Stream :: struct {
	client: *void; // IAudioClient
	service: *void; // IAudioRenderClient / IAudioCaptureClient
	event: win.HANDLE;
	frames: u32;
	thread: *thread.Thread;
	quit: bool; // atomic
	capture: bool;
}
#scope_file

Wasapi :: struct {
	enumerator: *void;
	out: Stream;
	inp: Stream;
}

wa: Wasapi;

open_stream :: (s: *Stream, capture: bool) -> bool {
	dev: *void;
	// GetDefaultAudioEndpoint(dataFlow: eRender 0 / eCapture 1, role: eConsole 0 / eCommunications 2)
	if (cast((*void, u32, u32, **void) -> win.HRESULT #c_call)vt(wa.enumerator, 4))(wa.enumerator, ifx capture then 1 else 0, ifx capture then 2 else 0, *dev) < 0 { return false; }
	defer release(dev);
	if (cast((*void, *win.GUID, u32, *void, **void) -> win.HRESULT #c_call)vt(dev, 3))(dev, *IID_IAudioClient, 1, null, *s.client) < 0 { return false; }
	ch: u16 = ifx capture then 1 else CHANNELS;
	f := WAVEFORMATEXTENSIBLE.{
		wFormatTag = 0xFFFE, nChannels = ch, nSamplesPerSec = SAMPLE_RATE,
		nAvgBytesPerSec = SAMPLE_RATE * 4 * cast(u32)(ch), nBlockAlign = 4 * ch, wBitsPerSample = 32,
		cbSize = 22, wValidBits = 32, dwChannelMask = ifx capture then 4 else 3, SubFormat = SUBTYPE_IEEE_FLOAT
	};
	flags: u32 = 0x40000 | 0x80000000 | 0x08000000; // EVENTCALLBACK | AUTOCONVERTPCM | SRC_DEFAULT_QUALITY
	if (cast((*void, u32, u32, s64, s64, *void, *void) -> win.HRESULT #c_call)vt(s.client, 3))(s.client, 0, flags, 100_000, 0, *f, null) < 0 {
		release(s.client);
		s.client = null;
		return false;
	}
	(cast((*void, *u32) -> win.HRESULT #c_call)vt(s.client, 4))(s.client, *s.frames);
	s.event = win.CreateEventW(null, false, false, null);
	(cast((*void, win.HANDLE) -> win.HRESULT #c_call)vt(s.client, 13))(s.client, s.event);
	iid := ifx capture then *IID_IAudioCaptureClient else *IID_IAudioRenderClient;
	(cast((*void, *win.GUID, **void) -> win.HRESULT #c_call)vt(s.client, 14))(s.client, iid, *s.service);
	s.capture = capture;
	if !capture {
		lat: s64;
		(cast((*void, *s64) -> win.HRESULT #c_call)vt(s.client, 5))(s.client, *lat);
		st.latency = cast(float64)(lat) / 10000000 + cast(float64)(s.frames) / SAMPLE_RATE;
	}
	return s.service != null;
}

close_stream :: (s: *Stream) {
	if s.client != null { (cast((*void) -> win.HRESULT #c_call)vt(s.client, 11))(s.client); }
	release(s.service);
	release(s.client);
	if s.event != null { win.CloseHandle(s.event); }
	s.client, s.service, s.event = null, null, null;
}

stream_thread :: (th: *thread.Thread) {
	s := cast(*Stream)(th.data);
	win.CoInitializeEx(null, .MULTITHREADED);
	defer win.CoUninitialize();
	scratch: [4096]float32;
	while !sync.atomic_load(*s.quit) {
		win.WaitForSingleObject(s.event, 200);
		if s.capture {
			while true {
				data: *float32;
				n: u32;
				flags: u32;
				hr := (cast((*void, **float32, *u32, *u32, *u64, *u64) -> win.HRESULT #c_call)vt(s.service, 3))(s.service, *data, *n, *flags, null, null);
				if hr != 0 || n == 0 { break; }
				if flags & 2 != 0 { 	// SILENT
					for i: 0..(min(cast(int)(n), len(scratch)))-1 { scratch[i] = 0; }
					ring_write(*st.capture, sub(scratch, 0, min(cast(int)(n), len(scratch))));
				} else {
					ring_write(*st.capture, sub(data, 0, n));
				}
				(cast((*void, u32) -> win.HRESULT #c_call)vt(s.service, 4))(s.service, n);
			}
			continue;
		}
		pad: u32;
		hr := (cast((*void, *u32) -> win.HRESULT #c_call)vt(s.client, 6))(s.client, *pad);
		if hr == AUDCLNT_E_DEVICE_INVALIDATED {
			// Default device changed / unplugged: reopen on the new default.
			close_stream(s);
			if !open_stream(s, false) { return; }
			(cast((*void) -> win.HRESULT #c_call)vt(s.client, 10))(s.client);
			continue;
		}
		avail := s.frames - pad;
		if avail == 0 { continue; }
		buf: *float32;
		if (cast((*void, u32, **float32) -> win.HRESULT #c_call)vt(s.service, 3))(s.service, avail, *buf) < 0 { continue; }
		sync.atomic_add(*st.callbacks, 1);
		mix(sub(buf, 0, avail * CHANNELS));
		(cast((*void, u32, u32) -> win.HRESULT #c_call)vt(s.service, 4))(s.service, avail, 0);
	}
}

start_stream :: (s: *Stream) {
	(cast((*void) -> win.HRESULT #c_call)vt(s.client, 10))(s.client);
	sync.atomic_store(*s.quit, false);
	s.thread = thread.create(stream_thread);
	s.thread.data = s;
	thread.start(s.thread);
}

stop_stream :: (s: *Stream) {
	if s.thread == null { return; }
	sync.atomic_store(*s.quit, true);
	win.SetEvent(s.event);
	thread.join(s.thread);
	thread.destroy(s.thread);
	s.thread = null;
	if s.client != null { (cast((*void) -> win.HRESULT #c_call)vt(s.client, 11))(s.client); }
}
#scope_module

_device_init :: () -> bool {
	win.CoInitializeEx(null, .MULTITHREADED);
	if win.CoCreateInstance(*CLSID_MMDeviceEnumerator, null, win.CLSCTX_ALL, *IID_IMMDeviceEnumerator, *wa.enumerator) < 0 { return false; }
	return open_stream(*wa.out, false);
}

_device_shutdown :: () {
	stop_stream(*wa.out);
	close_stream(*wa.out);
	release(wa.enumerator);
	wa = .{};
	st.running = false;
}

_device_start :: () {
	if st.running || wa.out.client == null { return; }
	start_stream(*wa.out);
	st.running = true;
}

_device_stop :: () {
	if !st.running { return; }
	stop_stream(*wa.out);
	st.running = false;
}

_capture_start :: (voice_processing: bool) -> bool {
	// TODO: voice processing via IAudioClient2::SetClientProperties(AUDIO_STREAM_CATEGORY_Communications)
	if !open_stream(*wa.inp, true) { return false; }
	start_stream(*wa.inp);
	return true;
}

_capture_stop :: () {
	stop_stream(*wa.inp);
	close_stream(*wa.inp);
}
#scope_export

