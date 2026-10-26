#+build windows
package audio

// WASAPI shared mode, event driven, f32 stereo 48 kHz (AUTOCONVERTPCM lets the
// engine resample/convert). Capture: separate mono client. Default-device
// changes are handled by re-opening on AUDCLNT_E_DEVICE_INVALIDATED.
// Compile-verified only.

import "core:sync"
import "core:thread"
import win "core:sys/windows"

@(private = "file")
vt :: #force_inline proc "contextless" (obj: rawptr, idx: int) -> rawptr {return (^[^]rawptr)(obj)^[idx]}

@(private = "file")
release :: proc "contextless" (obj: rawptr) {
	if obj != nil do (cast(proc "system" (rawptr) -> u32)vt(obj, 2))(obj)
}

@(private = "file") CLSID_MMDeviceEnumerator := win.GUID{0xBCDE0395, 0xE52F, 0x467C, {0x8E, 0x3D, 0xC4, 0x57, 0x92, 0x91, 0x69, 0x2E}}
@(private = "file") IID_IMMDeviceEnumerator := win.GUID{0xA95664D2, 0x9614, 0x4F35, {0xA7, 0x46, 0xDE, 0x8D, 0xB6, 0x36, 0x17, 0xE6}}
@(private = "file") IID_IAudioClient := win.GUID{0x1CB9AD4C, 0xDBFA, 0x4C32, {0xB1, 0x78, 0xC2, 0xF5, 0x68, 0xA7, 0x03, 0xB2}}
@(private = "file") IID_IAudioRenderClient := win.GUID{0xF294ACFC, 0x3146, 0x4483, {0xA7, 0xBF, 0xAD, 0xDC, 0xA7, 0xC2, 0x60, 0xE2}}
@(private = "file") IID_IAudioCaptureClient := win.GUID{0xC8ADBD64, 0xE71E, 0x48A0, {0xA4, 0xDE, 0x18, 0x5C, 0x39, 0x5C, 0xD3, 0x17}}
@(private = "file") SUBTYPE_IEEE_FLOAT := win.GUID{0x00000003, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71}}

@(private = "file")
WAVEFORMATEXTENSIBLE :: struct #packed {
	wFormatTag:      u16,
	nChannels:       u16,
	nSamplesPerSec:  u32,
	nAvgBytesPerSec: u32,
	nBlockAlign:     u16,
	wBitsPerSample:  u16,
	cbSize:          u16,
	wValidBits:      u16,
	dwChannelMask:   u32,
	SubFormat:       win.GUID,
}

@(private = "file")
AUDCLNT_E_DEVICE_INVALIDATED :: win.HRESULT(-2004287484) // 0x88890004

@(private = "file")
Stream :: struct {
	client:  rawptr, // IAudioClient
	service: rawptr, // IAudioRenderClient / IAudioCaptureClient
	event:   win.HANDLE,
	frames:  u32,
	thread:  ^thread.Thread,
	quit:    bool, // atomic
	capture: bool,
}

@(private = "file")
Wasapi :: struct {
	enumerator: rawptr,
	out:        Stream,
	inp:        Stream,
}

@(private = "file")
wa: Wasapi

@(private = "file")
open_stream :: proc(s: ^Stream, capture: bool) -> bool {
	dev: rawptr
	// GetDefaultAudioEndpoint(dataFlow: eRender 0 / eCapture 1, role: eConsole 0 / eCommunications 2)
	if (cast(proc "system" (rawptr, u32, u32, ^rawptr) -> win.HRESULT)vt(wa.enumerator, 4))(wa.enumerator, capture ? 1 : 0, capture ? 2 : 0, &dev) < 0 do return false
	defer release(dev)
	if (cast(proc "system" (rawptr, ^win.GUID, u32, rawptr, ^rawptr) -> win.HRESULT)vt(dev, 3))(dev, &IID_IAudioClient, 1 /*CLSCTX_INPROC_SERVER*/, nil, &s.client) < 0 do return false
	ch: u16 = capture ? 1 : CHANNELS
	f := WAVEFORMATEXTENSIBLE {
		wFormatTag = 0xFFFE, nChannels = ch, nSamplesPerSec = SAMPLE_RATE,
		nAvgBytesPerSec = SAMPLE_RATE * 4 * u32(ch), nBlockAlign = 4 * ch, wBitsPerSample = 32,
		cbSize = 22, wValidBits = 32, dwChannelMask = capture ? 4 : 3, SubFormat = SUBTYPE_IEEE_FLOAT,
	}
	flags: u32 = 0x40000 | 0x80000000 | 0x08000000 // EVENTCALLBACK | AUTOCONVERTPCM | SRC_DEFAULT_QUALITY
	if (cast(proc "system" (rawptr, u32, u32, i64, i64, rawptr, rawptr) -> win.HRESULT)vt(s.client, 3))(s.client, 0, flags, 100_000 /*10 ms*/, 0, &f, nil) < 0 {
		release(s.client)
		s.client = nil
		return false
	}
	(cast(proc "system" (rawptr, ^u32) -> win.HRESULT)vt(s.client, 4))(s.client, &s.frames)
	s.event = win.CreateEventW(nil, false, false, nil)
	(cast(proc "system" (rawptr, win.HANDLE) -> win.HRESULT)vt(s.client, 13))(s.client, s.event)
	iid := capture ? &IID_IAudioCaptureClient : &IID_IAudioRenderClient
	(cast(proc "system" (rawptr, ^win.GUID, ^rawptr) -> win.HRESULT)vt(s.client, 14))(s.client, iid, &s.service)
	s.capture = capture
	if !capture {
		lat: i64
		(cast(proc "system" (rawptr, ^i64) -> win.HRESULT)vt(s.client, 5))(s.client, &lat)
		st.latency = f64(lat) / 1e7 + f64(s.frames) / SAMPLE_RATE
	}
	return s.service != nil
}

@(private = "file")
close_stream :: proc(s: ^Stream) {
	if s.client != nil do (cast(proc "system" (rawptr) -> win.HRESULT)vt(s.client, 11))(s.client)
	release(s.service)
	release(s.client)
	if s.event != nil do win.CloseHandle(s.event)
	s.client, s.service, s.event = nil, nil, nil
}

@(private = "file")
stream_thread :: proc(th: ^thread.Thread) {
	s := (^Stream)(th.data)
	win.CoInitializeEx(nil, .MULTITHREADED)
	defer win.CoUninitialize()
	scratch: [4096]f32
	for !sync.atomic_load(&s.quit) {
		win.WaitForSingleObject(s.event, 200)
		if s.capture {
			for {
				data: [^]f32
				n: u32
				flags: u32
				hr := (cast(proc "system" (rawptr, ^[^]f32, ^u32, ^u32, ^u64, ^u64) -> win.HRESULT)vt(s.service, 3))(s.service, &data, &n, &flags, nil, nil)
				if hr != 0 || n == 0 do break
				if flags & 2 != 0 { 	// SILENT
					for i in 0 ..< min(int(n), len(scratch)) do scratch[i] = 0
					ring_write(&st.capture, scratch[:min(int(n), len(scratch))])
				} else {
					ring_write(&st.capture, data[:n])
				}
				(cast(proc "system" (rawptr, u32) -> win.HRESULT)vt(s.service, 4))(s.service, n)
			}
			continue
		}
		pad: u32
		hr := (cast(proc "system" (rawptr, ^u32) -> win.HRESULT)vt(s.client, 6))(s.client, &pad)
		if hr == AUDCLNT_E_DEVICE_INVALIDATED {
			// Default device changed / unplugged: reopen on the new default.
			close_stream(s)
			if !open_stream(s, false) do return
			(cast(proc "system" (rawptr) -> win.HRESULT)vt(s.client, 10))(s.client)
			continue
		}
		avail := s.frames - pad
		if avail == 0 do continue
		buf: [^]f32
		if (cast(proc "system" (rawptr, u32, ^[^]f32) -> win.HRESULT)vt(s.service, 3))(s.service, avail, &buf) < 0 do continue
		sync.atomic_add(&st.callbacks, 1)
		mix(buf[:avail * CHANNELS])
		(cast(proc "system" (rawptr, u32, u32) -> win.HRESULT)vt(s.service, 4))(s.service, avail, 0)
	}
}

@(private = "file")
start_stream :: proc(s: ^Stream) {
	(cast(proc "system" (rawptr) -> win.HRESULT)vt(s.client, 10))(s.client)
	sync.atomic_store(&s.quit, false)
	s.thread = thread.create(stream_thread)
	s.thread.data = s
	thread.start(s.thread)
}

@(private = "file")
stop_stream :: proc(s: ^Stream) {
	if s.thread == nil do return
	sync.atomic_store(&s.quit, true)
	win.SetEvent(s.event)
	thread.join(s.thread)
	thread.destroy(s.thread)
	s.thread = nil
	if s.client != nil do (cast(proc "system" (rawptr) -> win.HRESULT)vt(s.client, 11))(s.client)
}

@(private)
_device_init :: proc() -> bool {
	win.CoInitializeEx(nil, .MULTITHREADED)
	if win.CoCreateInstance(&CLSID_MMDeviceEnumerator, nil, win.CLSCTX_ALL, &IID_IMMDeviceEnumerator, &wa.enumerator) < 0 do return false
	return open_stream(&wa.out, false)
}

@(private)
_device_shutdown :: proc() {
	stop_stream(&wa.out)
	close_stream(&wa.out)
	release(wa.enumerator)
	wa = {}
	st.running = false
}

@(private)
_device_start :: proc() {
	if st.running || wa.out.client == nil do return
	start_stream(&wa.out)
	st.running = true
}

@(private)
_device_stop :: proc() {
	if !st.running do return
	stop_stream(&wa.out)
	st.running = false
}

@(private)
_capture_start :: proc(voice_processing: bool) -> bool {
	// TODO: voice processing via IAudioClient2::SetClientProperties(AUDIO_STREAM_CATEGORY_Communications)
	if !open_stream(&wa.inp, true) do return false
	start_stream(&wa.inp)
	return true
}

@(private)
_capture_stop :: proc() {
	stop_stream(&wa.inp)
	close_stream(&wa.inp)
}
