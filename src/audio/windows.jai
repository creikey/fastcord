// WASAPI shared mode, event driven, f32 stereo 48 kHz (AUTOCONVERTPCM lets the engine
// resample/convert). Capture: separate mono client. Each stream runs on the selected endpoint, else
// the default one (render: eConsole, capture: eCommunications). Its thread reopens it when the device
// is invalidated (unplugged), when the default changes while following it, when the selected device
// comes back and when the selection changes; with no device it retries until one appears. An
// IMMNotificationClient flags those and marks the cached device lists stale. Not compiled on macOS.

#scope_export

Device_Info :: struct {
	id: u32;
	name: string;
	uid: string; // the endpoint ID string
	is_default: bool;
}

// list_devices: active endpoints, cached until the notification client marks them stale. Ids last the
// session, one per endpoint ID.
list_devices :: (input: bool, allocator := context.allocator) -> []Device_Info {
	locks.guard(*dl.mu);
	if atomic_exchange(*dl.stale, false) for * dl.lists {
		push_allocator(context.default_allocator); // the lists outlive a caller's temp
		for it.* free(it.name);
		array_reset(it);
		enumerate_devices(it_index == 1, it);
	}
	src := dl.lists[cast(int) input];
	out := NewArray(src.count, Device_Info,, allocator);
	for src out[it_index] = .{id = it.id, name = copy_string(it.name,, allocator), uid = copy_string(it.uid,, allocator), is_default = it.is_default};
	return out;
}

selected_device :: (input: bool) -> u32 { return dl.sel[cast(int) input]; }

// select_device: 0 = follow the system default.
select_device :: (input: bool, id: u32) {
	{
		locks.guard(*dl.mu);
		dl.sel[cast(int) input] = ifx id <= dl.uids.count then id else 0;
	}
	apply_device_selection();
}

device_rate_changed :: () {}

// apply_device_selection: the stream threads reopen on the selected devices.
apply_device_selection :: () {
	atomic_store(*wa.out.reopen, true);
	atomic_store(*wa.inp.reopen, true);
}

#scope_module

device_init :: () -> bool {
	CoInitializeEx(null, COINIT_MULTITHREADED);
	if CoCreateInstance(*CLSID_MMDeviceEnumerator, null, CLSCTX_ALL, *IID_IMMDeviceEnumerator, *wa.enumerator) < 0 return false;
	notify_ctx = context;
	com(wa.enumerator, 6, #type (*void, *void) -> HRESULT #c_call)(wa.enumerator, *notify_client); // RegisterEndpointNotificationCallback
	return open_stream(*wa.out, false);
}

device_shutdown :: () {
	stop_stream(*wa.out);
	close_stream(*wa.out);
	if wa.enumerator com(wa.enumerator, 7, #type (*void, *void) -> HRESULT #c_call)(wa.enumerator, *notify_client); // Unregister...
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

device_capture_start :: () -> bool {
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
#import "Windows_Utf8";
ole32 :: #system_library "ole32";
CoInitializeEx :: (reserved: *void, coinit: u32) -> HRESULT #foreign ole32;
CoUninitialize :: () #foreign ole32;
CoCreateInstance :: (clsid: *GUID, outer: *void, cls_context: u32, iid: *GUID, out: **void) -> HRESULT #foreign ole32;
CoTaskMemFree :: (p: *void) #foreign ole32;
PropVariantClear :: (pv: *PROPVARIANT) -> HRESULT #foreign ole32;
SetEvent_ :: (event: HANDLE) -> s32 #foreign kernel32 "SetEvent";
kernel32 :: #system_library "kernel32";
COINIT_MULTITHREADED :: 0;
CLSCTX_ALL :: 0x17;
AUDCLNT_E_DEVICE_INVALIDATED :: cast(HRESULT) 0x88890004;
DEVICE_STATE_ACTIVE :: 1;
MAX_DEVICES :: 256;

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
PKEY_Device_FriendlyName := PROPERTYKEY.{.{0xA45C254E, 0xDF1C, 0x4EFD, .[0x80, 0x20, 0x67, 0xD1, 0x46, 0xA8, 0x50, 0xE0]}, 14};

PROPERTYKEY :: struct { fmtid: GUID; pid: u32; }
PROPVARIANT :: struct { vt: u16; reserved: [3]u16; p: *u16; pad: u64; } // p: pwszVal when vt is VT_LPWSTR (31)

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
	reopen: bool; // atomic: the thread reopens the stream
	capture: bool;
}

wa: struct {
	enumerator: *void;
	out: Stream;
	inp: Stream;
};

// The device lists and the selection outlive device_shutdown. [0] is output, [1] input.
dl: struct {
	mu: locks.Mutex;
	lists: [2][..]Device_Info; // names heap, uids point into uids
	uids: [..]string; // id - 1 -> endpoint ID, heap
	sel: [2]u32; // atomic reads from the stream threads; 0 = the default
	stale := true; // atomic: set by the notification client
};

// The selected endpoint ID (temp), "" when following the default.
selected_uid :: (capture: bool) -> string {
	locks.guard(*dl.mu);
	id := dl.sel[cast(int) capture];
	return ifx id then copy_string(dl.uids[id - 1],, temp) else "";
}

device_id :: (dev: *void) -> string {
	p: *u16;
	if com(dev, 5, #type (*void, **u16) -> HRESULT #c_call)(dev, *p) < 0 || !p return ""; // IMMDevice::GetId
	defer CoTaskMemFree(p);
	return wide_to_utf8(p,, temp);
}

// The selected endpoint if it is active, else the default one (AddRef'd, null when there is none).
endpoint :: (en: *void, capture: bool) -> *void {
	dev: *void;
	uid := selected_uid(capture);
	if uid && com(en, 5, #type (*void, *u16, **void) -> HRESULT #c_call)(en, utf8_to_wide(uid,, temp), *dev) >= 0 { // GetDevice
		state: u32;
		if com(dev, 6, #type (*void, *u32) -> HRESULT #c_call)(dev, *state) < 0 || state != DEVICE_STATE_ACTIVE { release(dev); dev = null; }
	}
	// GetDefaultAudioEndpoint(dataFlow: eRender 0 / eCapture 1, role: eConsole 0 / eCommunications 2)
	if !dev && com(en, 4, #type (*void, u32, u32, **void) -> HRESULT #c_call)(en, xx ifx capture then 1 else 0, xx ifx capture then 2 else 0, *dev) < 0 return null;
	return dev;
}

enumerate_devices :: (input: bool, out: *[..]Device_Info) {
	hr := CoInitializeEx(null, COINIT_MULTITHREADED); // any thread; an STA (the UI thread) keeps its own
	defer if hr >= 0 CoUninitialize();
	en, coll: *void;
	defer { release(coll); release(en); }
	if CoCreateInstance(*CLSID_MMDeviceEnumerator, null, CLSCTX_ALL, *IID_IMMDeviceEnumerator, *en) < 0 return;
	def: string;
	d: *void;
	if com(en, 4, #type (*void, u32, u32, **void) -> HRESULT #c_call)(en, xx ifx input then 1 else 0, xx ifx input then 2 else 0, *d) >= 0 {
		def = device_id(d);
		release(d);
	}
	n: u32;
	// EnumAudioEndpoints(dataFlow, DEVICE_STATE_ACTIVE); IMMDeviceCollection::GetCount, Item
	if com(en, 3, #type (*void, u32, u32, **void) -> HRESULT #c_call)(en, xx ifx input then 1 else 0, DEVICE_STATE_ACTIVE, *coll) < 0 ||
		com(coll, 3, #type (*void, *u32) -> HRESULT #c_call)(coll, *n) < 0 return;
	for i: 0..cast(s64) min(n, MAX_DEVICES) - 1 {
		dev, props: *void;
		if com(coll, 4, #type (*void, u32, **void) -> HRESULT #c_call)(coll, xx i, *dev) < 0 continue;
		defer { release(props); release(dev); }
		uid := device_id(dev);
		if !uid continue;
		name := uid;
		pv: PROPVARIANT;
		// IMMDevice::OpenPropertyStore(STGM_READ); IPropertyStore::GetValue
		if com(dev, 4, #type (*void, u32, **void) -> HRESULT #c_call)(dev, 0, *props) >= 0 &&
			com(props, 5, #type (*void, *PROPERTYKEY, *PROPVARIANT) -> HRESULT #c_call)(props, *PKEY_Device_FriendlyName, *pv) >= 0 {
			if pv.vt == 31 && pv.p name = wide_to_utf8(pv.p,, temp);
			PropVariantClear(*pv);
		}
		id := 0;
		for dl.uids if it == uid id = it_index + 1;
		if !id {
			array_add(*dl.uids, copy_string(uid));
			id = dl.uids.count;
		}
		array_add(out, .{id = xx id, name = copy_string(name), uid = dl.uids[id - 1], is_default = uid == def});
	}
}

// ---- IMMNotificationClient: a static object (a pointer to its vtable). Callbacks run on an MMDevAPI thread.

notify_ctx: #Context;

Notify_Vtbl :: struct {
	QueryInterface: (this: *void, riid: *GUID, out: **void) -> HRESULT #c_call;
	AddRef, Release: (this: *void) -> u32 #c_call;
	OnDeviceStateChanged: (this: *void, id: *u16, state: u32) -> HRESULT #c_call;
	OnDeviceAdded, OnDeviceRemoved: (this: *void, id: *u16) -> HRESULT #c_call;
	OnDefaultDeviceChanged: (this: *void, flow: u32, role: u32, id: *u16) -> HRESULT #c_call;
	OnPropertyValueChanged: (this: *void, id: *u16, key: *PROPERTYKEY) -> HRESULT #c_call;
}

notify_vtbl := Notify_Vtbl.{
	QueryInterface = (this: *void, riid: *GUID, out: **void) -> HRESULT #c_call {
		// IUnknown {00000000-0000-0000-C000-000000000046} / IMMNotificationClient {7991EEC9-7E89-4D85-8390-6C703CEC60C0}
		if riid && ((riid.Data1 == 0 && riid.Data4[0] == 0xC0) || (riid.Data1 == 0x7991EEC9 && riid.Data2 == 0x7E89)) {
			out.* = this;
			return 0;
		}
		out.* = null;
		return cast,no_check(HRESULT) 0x8000_4002; // E_NOINTERFACE
	},
	AddRef = (this: *void) -> u32 #c_call { return 1; },
	Release = (this: *void) -> u32 #c_call { return 1; },
	// A device coming (back) reopens a stream that selected it.
	OnDeviceStateChanged = (this: *void, id: *u16, state: u32) -> HRESULT #c_call { device_came(id); return 0; },
	OnDeviceAdded = (this: *void, id: *u16) -> HRESULT #c_call { device_came(id); return 0; },
	OnDeviceRemoved = (this: *void, id: *u16) -> HRESULT #c_call { atomic_store(*dl.stale, true); return 0; },
	OnDefaultDeviceChanged = (this: *void, flow: u32, role: u32, id: *u16) -> HRESULT #c_call {
		atomic_store(*dl.stale, true);
		// The roles the streams open: render eConsole, capture eCommunications. A stream reopens only while
		// following the default (an unplugged device is caught by AUDCLNT_E_DEVICE_INVALIDATED).
		if flow == 0 && role == 0 && atomic_load(*dl.sel[0]) == 0 atomic_store(*wa.out.reopen, true);
		if flow == 1 && role == 2 && atomic_load(*dl.sel[1]) == 0 atomic_store(*wa.inp.reopen, true);
		return 0;
	},
	OnPropertyValueChanged = (this: *void, id: *u16, key: *PROPERTYKEY) -> HRESULT #c_call { return 0; },
};
notify_client := *notify_vtbl;

device_came :: (id: *u16) #c_call {
	push_context notify_ctx {
		atomic_store(*dl.stale, true);
		uid := wide_to_utf8(id,, temp);
		for s: (*Stream).[*wa.out, *wa.inp] if selected_uid(s == *wa.inp) == uid atomic_store(*s.reopen, true);
		reset_temporary_storage();
	}
}

// ---- Streams

open_stream :: (s: *Stream, capture: bool) -> bool {
	s.capture = capture;
	dev := endpoint(wa.enumerator, capture);
	if !dev return false;
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
		if s.service WaitForSingleObject(s.event, 200);
		else sleep_milliseconds(500); // no device: retry until one appears
		if atomic_exchange(*s.reopen, false) || !s.service {
			close_stream(s);
			ok := open_stream(s, s.capture);
			reset_temporary_storage();
			if !ok { close_stream(s); continue; }
			com(s.client, 10, #type (*void) -> HRESULT #c_call)(s.client); // Start
		}
		if s.capture {
			while true {
				data: *float32;
				n, flags: u32;
				hr := com(s.service, 3, #type (*void, **float32, *u32, *u32, *u64, *u64) -> HRESULT #c_call)(s.service, *data, *n, *flags, null, null);
				if hr == AUDCLNT_E_DEVICE_INVALIDATED atomic_store(*s.reopen, true); // unplugged: the next turn reopens
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
		if hr == AUDCLNT_E_DEVICE_INVALIDATED { atomic_store(*s.reopen, true); continue; }
		avail := s.frames - pad;
		if hr < 0 || avail == 0 continue;
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
	atomic_store(*s.reopen, false);
	thread_init(*s.thread, stream_thread);
	s.thread.data = s;
	thread_start(*s.thread);
	s.thread_started = true;
}

stop_stream :: (s: *Stream) {
	if !s.thread_started return;
	atomic_store(*s.quit, true);
	if s.event SetEvent_(s.event);
	thread_is_done(*s.thread, -1);
	thread_deinit(*s.thread);
	s.thread_started = false;
	if s.client com(s.client, 11, #type (*void) -> HRESULT #c_call)(s.client); // Stop
}
