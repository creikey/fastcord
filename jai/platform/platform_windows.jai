#scope_file
	MsgWaitForMultipleObjectsEx :: (nCount: win.DWORD, pHandles: *win.HANDLE, dwMilliseconds: win.DWORD, dwWakeMask: win.DWORD, dwFlags: win.DWORD) -> win.DWORD #foreign user32;
	GetDoubleClickTime :: () -> win.UINT #foreign user32;
	SetWindowDisplayAffinity :: (hwnd: win.HWND, dwAffinity: win.DWORD) -> win.BOOL #foreign user32;

COMPOSITIONFORM :: struct {
	dwStyle: win.DWORD;
	ptCurrentPos: win.POINT;
	rcArea: win.RECT;
}
	ImmGetContext :: (hwnd: win.HWND) -> *void #foreign imm32;
	ImmReleaseContext :: (hwnd: win.HWND, himc: *void) -> win.BOOL #foreign imm32;
	ImmGetCompositionStringW :: (himc: *void, index: win.DWORD, buf: *void, len: win.DWORD) -> win.LONG #foreign imm32;
	ImmSetCompositionWindow :: (himc: *void, form: *COMPOSITIONFORM) -> win.BOOL #foreign imm32;

WM_FC_WAKE :: win.WM_USER + 1;
TIMER_ANIM :: 1;

Win :: struct {
	hwnd: win.HWND;
	instance: win.HINSTANCE;
	frame_wait: win.HANDLE; // swap chain frame-latency waitable (set by gfx)
	high_surrogate: u16;
	in_size_move: bool;
	tracking_mouse: bool;
	cursor_hidden: bool;
	last_click_time: float64;
	last_click_pos: [2]float32;
	last_click_btn: Mouse_Button;
	click_count: int;
	wake_posted: bool;
	composing: bool;
	drop_registered: bool;
}

w: Win;
#scope_export

native_window :: () -> *void {return cast(*void)(w.hwnd);}
native_view :: () -> *void {return cast(*void)(w.hwnd);}
native_metal_layer :: () -> *void {return null;}

// set_capture_hidden: WDA_EXCLUDEFROMCAPTURE (Electron's setContentProtection) or WDA_NONE.
set_capture_hidden :: (hidden: bool) {
	if w.hwnd != null { SetWindowDisplayAffinity(w.hwnd, ifx hidden then 0x11 else 0); }
}

// gfx registers the swap chain's frame-latency waitable object; wait_events
// waits on it (vsync pacing) when a frame was requested.
set_frame_wait_handle :: (h: *void) {w.frame_wait = win.HANDLE(h);}
#scope_module

_init :: (title: string, width: int, height: int) -> bool {
	win.SetProcessDpiAwarenessContext(win.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
	w.instance = win.HINSTANCE(win.GetModuleHandleW(null));
	class_name: cstring16 = "fastcord";
	wc := win.WNDCLASSEXW.{
		cbSize = size_of(win.WNDCLASSEXW),
		style = win.CS_HREDRAW | win.CS_VREDRAW | win.CS_OWNDC,
		lpfnWndProc = wndproc,
		hInstance = w.instance,
		hCursor = win.LoadCursorA(null, win.IDC_ARROW),
		lpszClassName = class_name
	};
	if win.RegisterClassExW(*wc) == 0 { return false; }

	style := win.WS_OVERLAPPEDWINDOW;
	dpi := win.GetDpiForSystem();
	scale := cast(float32)(dpi) / 96;
	r := win.RECT.{0, 0, cast(s32)(cast(float32)(width) * scale), cast(s32)(cast(float32)(height) * scale)};
	win.AdjustWindowRectExForDpi(*r, style, false, 0, dpi);
	w.hwnd = win.CreateWindowExW(0, class_name, win.utf8_to_wstring(title), style,
		win.CW_USEDEFAULT, win.CW_USEDEFAULT, r.right - r.left, r.bottom - r.top, null, null, w.instance, null);
	if w.hwnd == null { return false; }
	// IDropTarget gives drag enter/leave (the "Upload to #channel" overlay); WM_DROPFILES is the fallback.
	if !drop_target_register(w.hwnd) { win.DragAcceptFiles(w.hwnd, true); }
	update_size();
	update_refresh();
	win.ShowWindow(w.hwnd, win.SW_SHOW);
	win.UpdateWindow(w.hwnd);
	return true;
}

_shutdown :: () {
	if w.hwnd != null && w.drop_registered { RevokeDragDrop(w.hwnd); }
	if w.hwnd != null { win.DestroyWindow(w.hwnd); }
	w.hwnd = null;
}
#scope_file

update_size :: () {
	r: win.RECT;
	win.GetClientRect(w.hwnd, *r);
	dpi := win.GetDpiForWindow(w.hwnd);
	s.scale = cast(float32)(dpi) / 96;
	if s.scale <= 0 { s.scale = 1; }
	s.size = .{cast(float32)(r.right - r.left) / s.scale, cast(float32)(r.bottom - r.top) / s.scale};
}

update_refresh :: () {
	dm: win.DEVMODEW;
	dm.dmSize = size_of(dm);
	if win.EnumDisplaySettingsW(null, win.ENUM_CURRENT_SETTINGS, *dm) && dm.dmDisplayFrequency > 1 {
		s.refresh_hz = cast(float32)(dm.dmDisplayFrequency);
	}
}
#scope_module

_wake :: () {
	if atomic_exchange(*w.wake_posted, true) { return; }
	win.PostMessageW(w.hwnd, WM_FC_WAKE, 0, 0);
}

_wait :: (timeout: float64) {
	start := time_now();
	while true {
		pump();
		animating := atomic_load(*s.frame_requested);
		if s.quit { return; }
		if !animating && pending_count() > 0 { return; }
		ms: win.DWORD = win.INFINITE;
		if timeout >= 0 {
			remaining := timeout - (time_now() - start);
			if remaining <= 0 { return; }
			ms = win.DWORD(remaining * 1000);
		}
		handles: [1]win.HANDLE;
		n: win.DWORD = 0;
		if animating {
			if w.frame_wait != null {
				handles[0] = w.frame_wait;
				n = 1;
			} else {
				ms = min(ms, win.DWORD(1000 / max(s.refresh_hz, 30)));
			}
		}
		r := MsgWaitForMultipleObjectsEx(n, ifx n > 0 then *handles[0] else null, ms, win.QS_ALLINPUT, 0x0004 /*MWMO_INPUTAVAILABLE*/);
		if animating {
			if n > 0 && r == win.WAIT_OBJECT_0 {
				pump();
				return; // vsync: swap chain ready for the next frame
			}
			if n == 0 && r == win.WAIT_TIMEOUT {
				pump();
				return;
			}
		}
		if r == win.WAIT_TIMEOUT && timeout >= 0 && time_now() - start >= timeout {
			pump();
			return;
		}
	}
}
#scope_file

pump :: () {
	msg: win.MSG;
	while win.PeekMessageW(*msg, null, 0, 0, win.PM_REMOVE) {
		if msg.message == win.WM_QUIT {
			s.quit = true;
			push_event(.{kind = .Quit, time = time_now()});
			continue;
		}
		win.TranslateMessage(*msg);
		win.DispatchMessageW(*msg);
	}
}
#scope_module

_clipboard_get :: (allocator: Allocator) -> string {
	if !win.OpenClipboard(w.hwnd) { return ""; }
	defer win.CloseClipboard();
	h := win.GetClipboardData(win.CF_UNICODETEXT);
	if h == null { return ""; }
	p := cast(*u16)(win.GlobalLock(win.HGLOBAL(h)));
	if p == null { return ""; }
	defer win.GlobalUnlock(win.HGLOBAL(h));
	n := 0;
	while p[n] != 0 { n += 1; }
	out, _ := win.utf16_to_utf8(sub(p, 0, n), allocator);
	return out;
}

_clipboard_set :: (str: string) {
	wide := win.utf8_to_utf16(str, temp);
	if !win.OpenClipboard(w.hwnd) { return; }
	defer win.CloseClipboard();
	win.EmptyClipboard();
	bytes := (len(wide) + 1) * 2;
	h := win.GlobalAlloc(win.GMEM_MOVEABLE, cast(u64)(bytes));
	if h == null { return; }
	p := cast(*u16)(win.GlobalLock(win.HGLOBAL(h)));
	copy(sub(p, 0, len(wide)), wide);
	p[len(wide)] = 0;
	win.GlobalUnlock(win.HGLOBAL(h));
	win.SetClipboardData(win.CF_UNICODETEXT, win.HANDLE(h));
}
#scope_file

// ---- Clipboard: images and files

cf_png :: () -> win.UINT {
	if static_id1 == 0 { id = win.RegisterClipboardFormatW(win.L("PNG")); }
	return static_id1;
}
#scope_module

_clipboard_kind :: () -> Clipboard_Kind {
	if win.IsClipboardFormatAvailable(win.CF_HDROP) { return .Files; }
	if win.IsClipboardFormatAvailable(cf_png()) || win.IsClipboardFormatAvailable(win.CF_DIBV5) || win.IsClipboardFormatAvailable(win.CF_DIB) { return .Image; }
	if win.IsClipboardFormatAvailable(win.CF_UNICODETEXT) { return .Text; }
	return .None;
}
#scope_file

// Opens the clipboard from a worker thread (no window): retried briefly, another
// process may hold it.
open_clipboard_any :: () -> bool {
	for _: 0..9 {
		if win.OpenClipboard(null) { return true; }
		win.Sleep(10);
	}
	return false;
}

global_bytes :: (h: win.HANDLE, allocator: Allocator) -> []u8 {
	if h == null { return .{}; }
	p := cast(*u8)(win.GlobalLock(win.HGLOBAL(h)));
	if p == null { return .{}; }
	defer win.GlobalUnlock(win.HGLOBAL(h));
	n := cast(int)(win.GlobalSize(cast(*void)(h)));
	out := make_slice(u8, n, allocator);
	copy(out, sub(p, 0, n));
	return out;
}
#scope_module

// "PNG" (browsers, Office) as is; else CF_DIBV5 / CF_DIB (screenshots) encoded as PNG by WIC.
_clipboard_image :: (allocator: Allocator) -> []u8, bool {
	if !open_clipboard_any() { return .{}, false; }
	defer win.CloseClipboard();
	{ b := global_bytes(win.GetClipboardData(cf_png()), allocator);
	if len(b) > 0 { return b, true; } }
	dib := global_bytes(win.GetClipboardData(win.CF_DIBV5), temp);
	if len(dib) == 0 { dib = global_bytes(win.GetClipboardData(win.CF_DIB), temp); }
	rgba, w, h, ok := dib_to_rgba(dib, temp);
	if !ok { return .{}, false; }
	png := wic_png(rgba, w, h, allocator);
	return png, len(png) > 0;
}
#scope_file

CLSID_WICImagingFactory := win.GUID.{0xCACAF262, 0x9370, 0x4615, .{0xA1, 0x3B, 0x9F, 0x55, 0x39, 0xDA, 0x4C, 0x0A}};
IID_IWICImagingFactory := win.GUID.{0xEC5EC8A9, 0xC395, 0x4314, .{0x9C, 0x77, 0x54, 0xD7, 0xA9, 0x35, 0xFF, 0x70}};
GUID_ContainerFormatPng := win.GUID.{0x1B7CFAF4, 0x713F, 0x473C, .{0xBB, 0xCD, 0x61, 0x37, 0x42, 0x5F, 0xAE, 0xAF}};
GUID_WICPixelFormat32bppBGRA := win.GUID.{0x6FDDC324, 0x4E03, 0x4BFE, .{0xB1, 0x85, 0x3D, 0x77, 0x76, 0x8D, 0xC9, 0x0F}};

vt :: inline (obj: *void, idx: int) -> *void #no_context {return (cast(***void)(obj)).*[idx];};

release :: (obj: *void) #no_context {
	if obj != null { (cast((*void) -> u32 #c_call)vt(obj, 2))(obj); }
}

// wic_png: RGBA8 pixels (swapped to BGRA in place) as PNG, by WIC's PNG encoder (the OS's, as
// NSBitmapImageRep is on macOS). nil on failure. Worker thread.
wic_png :: (px: []u8, w: int, h: int, allocator: Allocator) -> []u8 {
	{ i := 0;
	while i < len(px) { px[i], px[i + 2] = px[i + 2], px[i];  i += 4; } }
	com := win.CoInitializeEx(null, .MULTITHREADED) >= 0;
	defer if com { win.CoUninitialize(); }
	factory, enc, frame: *void;
	stream: *win.IStream;
	defer {
		release(frame);
		release(enc);
		release(stream);
		release(factory);
	}
	format := GUID_WICPixelFormat32bppBGRA;
	// IWICImagingFactory::CreateEncoder; IWICBitmapEncoder::Initialize (WICBitmapEncoderNoCache),
	// CreateNewFrame, Commit; IWICBitmapFrameEncode::Initialize, SetSize, SetPixelFormat, WritePixels, Commit
	ok :=
		win.CoCreateInstance(*CLSID_WICImagingFactory, null, win.CLSCTX_INPROC_SERVER, *IID_IWICImagingFactory, *factory) >= 0 &&
		(cast((*void, *win.GUID, *win.GUID, **void) -> win.HRESULT #c_call)vt(factory, 8))(factory, *GUID_ContainerFormatPng, null, *enc) >= 0 &&
		CreateStreamOnHGlobal(null, true, *stream) >= 0 &&
		(cast((*void, *void, u32) -> win.HRESULT #c_call)vt(enc, 3))(enc, stream, 2) >= 0 &&
		(cast((*void, **void, *void) -> win.HRESULT #c_call)vt(enc, 10))(enc, *frame, null) >= 0 &&
		(cast((*void, *void) -> win.HRESULT #c_call)vt(frame, 3))(frame, null) >= 0 &&
		(cast((*void, u32, u32) -> win.HRESULT #c_call)vt(frame, 4))(frame, cast(u32)(w), cast(u32)(h)) >= 0 &&
		(cast((*void, *win.GUID) -> win.HRESULT #c_call)vt(frame, 6))(frame, *format) >= 0 &&
		format == GUID_WICPixelFormat32bppBGRA &&
		(cast((*void, u32, u32, u32, *u8) -> win.HRESULT #c_call)vt(frame, 10))(frame, cast(u32)(h), cast(u32)(w * 4), cast(u32)(len(px)), raw_data(px)) >= 0 &&
		(cast((*void) -> win.HRESULT #c_call)vt(frame, 12))(frame) >= 0 &&
		(cast((*void) -> win.HRESULT #c_call)vt(enc, 11))(enc) >= 0;
	size: win.ULARGE_INTEGER;
	if !ok || stream->Seek(0, 2, *size) < 0 || stream->Seek(0, 0, null) < 0 { return .{}; }
	out := make_slice(u8, cast(int)(size), allocator);
	got: win.ULONG;
	if stream->Read(raw_data(out), win.ULONG(size), *got) < 0 || cast(int)(got) != len(out) {
		delete(out, allocator);
		return .{};
	}
	return out;
}

hdrop_paths :: (hdrop: win.HDROP, allocator: Allocator) -> []string {
	out := make_dynamic(string, 0, 0, allocator);
	n := win.DragQueryFileW(hdrop, 0xFFFFFFFF, null, 0);
	for i: 0..n-1 {
		l := win.DragQueryFileW(hdrop, i, null, 0);
		buf := make_slice(u16, l + 1, temp);
		win.DragQueryFileW(hdrop, i, raw_data(buf), l + 1);
		path, _ := win.utf16_to_utf8(sub(buf, 0, l), allocator);
		append(*out, path);
	}
	return view(out);
}
#scope_module

_clipboard_files :: (allocator: Allocator) -> []string {
	if !open_clipboard_any() { return .{}; }
	defer win.CloseClipboard();
	h := win.GetClipboardData(win.CF_HDROP);
	if h == null { return .{}; }
	return hdrop_paths(win.HDROP(h), allocator);
}
#scope_file
	OleInitialize :: (reserved: *void) -> win.HRESULT #foreign ole32;
	RegisterDragDrop :: (hwnd: win.HWND, target: *void) -> win.HRESULT #foreign ole32;
	RevokeDragDrop :: (hwnd: win.HWND) -> win.HRESULT #foreign ole32;
	ReleaseStgMedium :: (medium: *STGMEDIUM) #foreign ole32;
	CreateStreamOnHGlobal :: (h: win.HGLOBAL, delete_on_release: win.BOOL, stream: **win.IStream) -> win.HRESULT #foreign ole32;

FORMATETC :: struct {
	cfFormat: u16;
	ptd: *void;
	dwAspect: u32;
	lindex: s32;
	tymed: u32;
}

STGMEDIUM :: struct {
	tymed: u32;
	handle: *void; // hGlobal for TYMED_HGLOBAL
	pUnkForRelease: *void;
}

IDataObject_Vtbl :: struct {
	QueryInterface: *void;
	AddRef: *void;
	Release: *void;
	GetData: (this: *IDataObject, fmt: *FORMATETC, medium: *STGMEDIUM) -> win.HRESULT #c_call;
	// the rest is not called
}

IDataObject :: struct {
	vtbl: *IDataObject_Vtbl;
}

POINTL :: struct {
	x, y: s32;
}

IDropTarget_Vtbl :: struct {
	QueryInterface: (this: *void, riid: *win.GUID, out: **void) -> win.HRESULT #c_call;
	AddRef: (this: *void) -> u32 #c_call;
	Release: (this: *void) -> u32 #c_call;
	DragEnter: (this: *void, data: *IDataObject, keys: u32, pt: POINTL, effect: *u32) -> win.HRESULT #c_call;
	DragOver: (this: *void, keys: u32, pt: POINTL, effect: *u32) -> win.HRESULT #c_call;
	DragLeave: (this: *void) -> win.HRESULT #c_call;
	Drop: (this: *void, data: *IDataObject, keys: u32, pt: POINTL, effect: *u32) -> win.HRESULT #c_call;
}

Drop_Target :: struct {
	vtbl: *IDropTarget_Vtbl;
}

DROPEFFECT_COPY :: 1;

drop_vtbl := IDropTarget_Vtbl.{
	QueryInterface = (this: *void, riid: *win.GUID, out: **void) -> win.HRESULT #c_call {
		// IUnknown {00000000-0000-0000-C000-000000000046} / IDropTarget {00000122-0000-0000-C000-000000000046}
		if riid != null && (riid.Data1 == 0 || riid.Data1 == 0x122) && riid.Data2 == 0 && riid.Data3 == 0 && riid.Data4[0] == 0xC0 && riid.Data4[7] == 0x46 {
			out.* = this;
			return 0;
		}
		out.* = null;
		return transmute(win.HRESULT, cast(u32)(0x80004002)); // E_NOINTERFACE
	},
	AddRef = (this: *void) -> u32 #c_call {return 1;}, // static object
	Release = (this: *void) -> u32 #c_call {return 1;},
	DragEnter = (this: *void, data: *IDataObject, keys: u32, pt: POINTL, effect: *u32) -> win.HRESULT #c_call {
		__ctx2 := s.ctx; push_context,defer_pop __ctx2;
		p := win.POINT.{pt.x, pt.y};
		win.ScreenToClient(w.hwnd, *p);
		push_event(.{kind = .Drag_Enter, pos = .{cast(float32)(p.x) / s.scale, cast(float32)(p.y) / s.scale}, time = time_now()});
		if effect != null { effect.* = DROPEFFECT_COPY; }
		return 0;
	},
	DragOver = (this: *void, keys: u32, pt: POINTL, effect: *u32) -> win.HRESULT #c_call {
		if effect != null { effect.* = DROPEFFECT_COPY; }
		return 0;
	},
	DragLeave = (this: *void) -> win.HRESULT #c_call {
		__ctx3 := s.ctx; push_context,defer_pop __ctx3;
		push_event(.{kind = .Drag_Leave, time = time_now()});
		return 0;
	},
	Drop = (this: *void, data: *IDataObject, keys: u32, pt: POINTL, effect: *u32) -> win.HRESULT #c_call {
		__ctx4 := s.ctx; push_context,defer_pop __ctx4;
		if data != null {
			f := FORMATETC.{cfFormat = win.CF_HDROP, dwAspect = 1, lindex = -1, tymed = 1 /*TYMED_HGLOBAL*/};
			med: STGMEDIUM;
			if data.vtbl.GetData(data, *f, *med) == 0 {
				for path: hdrop_paths(win.HDROP(med.handle), temp) {
					push_event(.{kind = .File_Drop, text = path, time = time_now()});
				}
				ReleaseStgMedium(*med);
			}
		}
		push_event(.{kind = .Drag_Leave, time = time_now()});
		if effect != null { effect.* = DROPEFFECT_COPY; }
		return 0;
	}
};

drop_target := Drop_Target.{*drop_vtbl};

drop_target_register :: (hwnd: win.HWND) -> bool {
	hr := OleInitialize(null);
	if hr < 0 { return false; }
	if RegisterDragDrop(hwnd, *drop_target) < 0 { return false; }
	w.drop_registered = true;
	return true;
}
#scope_module

_apply_cursor :: () {
	if s.cursor == .Hidden {
		win.SetCursor(null);
		return;
	}
	id: u64;
	if s.cursor == {
	case .Arrow; #through; case .Hidden; id = 32512;
	case .Pointer;        id = 32649;
	case .IBeam;          id = 32513;
	case .Resize_H;       id = 32644;
	case .Resize_V;       id = 32645;
	case .Resize_NWSE;    id = 32642;
	case .Resize_NESW;    id = 32643;
	case .Move;           id = 32646;
	case .Not_Allowed;    id = 32648;
	case .Crosshair;      id = 32515;
	}
	win.SetCursor(win.LoadCursorA(null, to_cstring(cast(*void)(id))));
}
#scope_file

// ---------------------------------------------------------------------------

current_mods :: () -> Mods {
	m: Mods;
	if win.GetKeyState(win.VK_SHIFT) < 0 { m += .{.Shift}; }
	if win.GetKeyState(win.VK_CONTROL) < 0 { m += .{.Ctrl}; }
	if win.GetKeyState(win.VK_MENU) < 0 { m += .{.Alt}; }
	if win.GetKeyState(win.VK_LWIN) < 0 || win.GetKeyState(win.VK_RWIN) < 0 { m += .{.Cmd}; }
	return m;
}

map_vk :: (vk: win.WPARAM, lparam: win.LPARAM) -> Key {
	if (vk >= #char "A" && vk <= #char "Z") { return cast(Key)(cast(int)(Key.A) + cast(int)(vk - #char "A"));
	} else if (vk >= #char "0" && vk <= #char "9") { return cast(Key)(cast(int)(Key.N0) + cast(int)(vk - #char "0"));
	} else if vk == win.VK_SPACE {  return .Space;
	} else if vk == win.VK_RETURN { return ifx (lparam >> 24) & 1 != 0 then .Keypad_Enter else .Enter;
	} else if vk == win.VK_TAB {    return .Tab;
	} else if vk == win.VK_BACK {   return .Backspace;
	} else if vk == win.VK_DELETE { return .Delete;
	} else if vk == win.VK_ESCAPE { return .Escape;
	} else if vk == win.VK_LEFT {   return .Left;
	} else if vk == win.VK_RIGHT {  return .Right;
	} else if vk == win.VK_UP {     return .Up;
	} else if vk == win.VK_DOWN {   return .Down;
	} else if vk == win.VK_HOME {   return .Home;
	} else if vk == win.VK_END {    return .End;
	} else if vk == win.VK_PRIOR {  return .Page_Up;
	} else if vk == win.VK_NEXT {   return .Page_Down;
	} else if vk == win.VK_SHIFT || vk == win.VK_LSHIFT || vk == win.VK_RSHIFT { return .Shift;
	} else if vk == win.VK_CONTROL || vk == win.VK_LCONTROL || vk == win.VK_RCONTROL { return .Ctrl;
	} else if vk == win.VK_MENU || vk == win.VK_LMENU || vk == win.VK_RMENU { return .Alt;
	} else if vk == win.VK_LWIN || vk == win.VK_RWIN { return .Cmd;
	} else if vk == win.VK_CAPITAL { return .Caps_Lock;
	} else if (vk >= win.VK_F1 && vk <= win.VK_F12) { return cast(Key)(cast(int)(Key.F1) + cast(int)(vk - win.VK_F1));
	} else if vk == win.VK_OEM_MINUS {  return .Minus;
	} else if vk == win.VK_OEM_PLUS {   return .Equals;
	} else if vk == win.VK_OEM_4 {      return .Left_Bracket;
	} else if vk == win.VK_OEM_6 {      return .Right_Bracket;
	} else if vk == win.VK_OEM_5 {      return .Backslash;
	} else if vk == win.VK_OEM_1 {      return .Semicolon;
	} else if vk == win.VK_OEM_7 {      return .Apostrophe;
	} else if vk == win.VK_OEM_COMMA {  return .Comma;
	} else if vk == win.VK_OEM_PERIOD { return .Period;
	} else if vk == win.VK_OEM_2 {      return .Slash;
	} else if vk == win.VK_OEM_3 {      return .Grave;
	}
	return .None;
}

lparam_pos :: (lp: win.LPARAM) -> [2]float32 {
	x := cast(float32)(win.GET_X_LPARAM(lp));
	y := cast(float32)(win.GET_Y_LPARAM(lp));
	return .[x / s.scale, y / s.scale];
}

mouse_button_event :: (kind: Event_Kind, btn: Mouse_Button, lp: win.LPARAM) {
	pos := lparam_pos(lp);
	e := Event.{kind = kind, button = btn, pos = pos, mods = current_mods(), time = time_now()};
	if kind == .Mouse_Down {
		now := time_now();
		dbl := cast(float64)(GetDoubleClickTime()) / 1000;
		d := pos - w.last_click_pos;
		if btn == w.last_click_btn && now - w.last_click_time <= dbl && d.x * d.x + d.y * d.y < 16 {
			w.click_count += 1;
		} else {
			w.click_count = 1;
		}
		w.last_click_time = now;
		w.last_click_pos = pos;
		w.last_click_btn = btn;
		win.SetCapture(w.hwnd);
	} else {
		win.ReleaseCapture();
	}
	e.click_count = w.click_count;
	push_event(e);
}

update_ime_window :: () {
	himc := ImmGetContext(w.hwnd);
	if himc == null { return; }
	defer ImmReleaseContext(w.hwnd, himc);
	cf := COMPOSITIONFORM.{dwStyle = 0x0002, ptCurrentPos = .{cast(s32)(s.ime_rect[0] * s.scale), cast(s32)((s.ime_rect[1] + s.ime_rect[3]) * s.scale)}};
	ImmSetCompositionWindow(himc, *cf);
}

wndproc :: (hwnd: win.HWND, msg: win.UINT, wp: win.WPARAM, lp: win.LPARAM) -> win.LRESULT #c_call {
	__ctx7 := s.ctx; push_context,defer_pop __ctx7;
	for __sw8: 0..0 { if msg == {
	case WM_FC_WAKE;
		atomic_store(*w.wake_posted, false);
		return 0;
	case win.WM_CLOSE;
		s.quit = true;
		push_event(.{kind = .Quit, time = time_now()});
		return 0;
	case win.WM_SIZE;
		update_size();
		push_event(.{kind = .Resize, pos = s.size, time = time_now()});
		if w.in_size_move { run_frame_callback(); }
		return 0;
	case win.WM_GETMINMAXINFO;
		mm := cast(*win.MINMAXINFO)(cast(u64)(lp));
		dpi := win.GetDpiForWindow(hwnd);
		sc := cast(float32)(dpi) / 96;
		r := win.RECT.{0, 0, cast(s32)(MIN_WINDOW_W * sc), cast(s32)(MIN_WINDOW_H * sc)};
		win.AdjustWindowRectExForDpi(*r, win.WS_OVERLAPPEDWINDOW, false, 0, dpi);
		mm.ptMinTrackSize = .{r.right - r.left, r.bottom - r.top};
		return 0;
	case win.WM_DPICHANGED;
		r := cast(*win.RECT)(cast(u64)(lp));
		win.SetWindowPos(hwnd, null, r.left, r.top, r.right - r.left, r.bottom - r.top, win.SWP_NOZORDER | win.SWP_NOACTIVATE);
		update_size();
		push_event(.{kind = .Resize, pos = s.size, time = time_now()});
		return 0;
	case win.WM_ENTERSIZEMOVE;
		w.in_size_move = true;
		win.SetTimer(hwnd, TIMER_ANIM, 1, null);
		return 0;
	case win.WM_EXITSIZEMOVE;
		w.in_size_move = false;
		win.KillTimer(hwnd, TIMER_ANIM);
		return 0;
	case win.WM_TIMER;
		if wp == TIMER_ANIM && w.in_size_move && atomic_load(*s.frame_requested) { run_frame_callback(); }
		return 0;
	case win.WM_SETFOCUS;
		push_event(.{kind = .Focus_Gained, time = time_now()});
		return 0;
	case win.WM_KILLFOCUS;
		push_event(.{kind = .Focus_Lost, time = time_now()});
		return 0;
	case win.WM_SETCURSOR;
		if win.LOWORD(win.DWORD(lp)) == win.HTCLIENT {
			_apply_cursor();
			return 1;
		}
	case win.WM_KEYDOWN; #through; case win.WM_SYSKEYDOWN;
		k := map_vk(wp, lp);
		push_event(.{kind = .Key_Down, key = k, mods = current_mods(), is_repeat = (lp >> 30) & 1 != 0, time = time_now()});
		if msg == win.WM_SYSKEYDOWN && wp == win.VK_F4 { break __sw8; } // let Alt+F4 through
		if msg == win.WM_SYSKEYDOWN { return 0; }
		return 0;
	case win.WM_KEYUP; #through; case win.WM_SYSKEYUP;
		push_event(.{kind = .Key_Up, key = map_vk(wp, lp), mods = current_mods(), time = time_now()});
		return 0;
	case win.WM_CHAR;
		c := cast(u16)(wp);
		if c >= 0xD800 && c <= 0xDBFF {
			w.high_surrogate = c;
			return 0;
		}
		buf: [2]u16;
		n := 0;
		if c >= 0xDC00 && c <= 0xDFFF && w.high_surrogate != 0 {
			buf = .{w.high_surrogate, c};
			n = 2;
		} else {
			buf[0] = c;
			n = 1;
		}
		w.high_surrogate = 0;
		if n == 1 && (c < 0x20 || c == 0x7f) { return 0; }
		mods := current_mods();
		if has(mods, .Ctrl) && !has(mods, .Alt) { return 0; } // ctrl shortcuts are Key_Down only (AltGr = ctrl+alt types text)
		utf8buf: [8]u8;
		l := utf16.decode_to_utf8(view(utf8buf), sub(buf, 0, n));
		push_event(.{kind = .Text, text = as_string(sub(utf8buf, 0, l)), time = time_now()});
		return 0;
	case win.WM_IME_STARTCOMPOSITION;
		update_ime_window();
		w.composing = true;
	case win.WM_IME_COMPOSITION;
		update_ime_window();
		if lp & 0x0008 /*GCS_COMPSTR*/ != 0 {
			himc := ImmGetContext(hwnd);
			if himc != null {
				bytes := ImmGetCompositionStringW(himc, 0x0008, null, 0);
				text := "";
				if bytes > 0 {
					wbuf := make_slice(u16, bytes / 2, temp);
					ImmGetCompositionStringW(himc, 0x0008, raw_data(wbuf), win.DWORD(bytes));
					text, _ = win.utf16_to_utf8(wbuf, temp);
				}
				cursor := ImmGetCompositionStringW(himc, 0x0080, null, 0);
				ImmReleaseContext(hwnd, himc);
				cb := utf16_offset_to_byte(text, cast(int)(cursor));
				push_event(.{kind = .Composition, text = text, composition_sel = .{cb, cb}, time = time_now()});
			}
		}
		// GCS_RESULTSTR arrives as WM_CHAR via DefWindowProc
	case win.WM_IME_ENDCOMPOSITION;
		if w.composing {
			w.composing = false;
			push_event(.{kind = .Composition, time = time_now()});
		}
	case win.WM_MOUSEMOVE;
		if !w.tracking_mouse {
			tme := win.TRACKMOUSEEVENT.{cbSize = size_of(win.TRACKMOUSEEVENT), dwFlags = win.TME_LEAVE, hwndTrack = hwnd};
			win.TrackMouseEvent(*tme);
			w.tracking_mouse = true;
		}
		push_event(.{kind = .Mouse_Move, pos = lparam_pos(lp), mods = current_mods(), time = time_now()});
		return 0;
	case win.WM_MOUSELEAVE;
		w.tracking_mouse = false;
		push_event(.{kind = .Mouse_Leave, time = time_now()});
		return 0;
	case win.WM_LBUTTONDOWN; mouse_button_event(.Mouse_Down, .Left, lp); return 0;
	case win.WM_LBUTTONUP;   mouse_button_event(.Mouse_Up, .Left, lp); return 0;
	case win.WM_RBUTTONDOWN; mouse_button_event(.Mouse_Down, .Right, lp); return 0;
	case win.WM_RBUTTONUP;   mouse_button_event(.Mouse_Up, .Right, lp); return 0;
	case win.WM_MBUTTONDOWN; mouse_button_event(.Mouse_Down, .Middle, lp); return 0;
	case win.WM_MBUTTONUP;   mouse_button_event(.Mouse_Up, .Middle, lp); return 0;
	case win.WM_XBUTTONDOWN; mouse_button_event(.Mouse_Down, ifx win.HIWORD(win.DWORD(wp)) == 1 then .X1 else .X2, lp); return 1;
	case win.WM_XBUTTONUP;   mouse_button_event(.Mouse_Up, ifx win.HIWORD(win.DWORD(wp)) == 1 then .X1 else .X2, lp); return 1;
	case win.WM_MOUSEWHEEL; #through; case win.WM_MOUSEHWHEEL;
		delta := cast(float32)(win.GET_WHEEL_DELTA_WPARAM(wp)) / 120 * 40; // Chrome: 40px per notch
		pt := win.POINT.{win.GET_X_LPARAM(lp), win.GET_Y_LPARAM(lp)};
		win.ScreenToClient(hwnd, *pt);
		e := Event.{kind = .Scroll, pos = .{cast(float32)(pt.x) / s.scale, cast(float32)(pt.y) / s.scale}, mods = current_mods(), time = time_now()};
		if msg == win.WM_MOUSEWHEEL { e.delta.y = delta; } else { e.delta.x = -delta; }
		push_event(e);
		return 0;
	case win.WM_DROPFILES;
		hdrop := win.HDROP(wp);
		for path: hdrop_paths(hdrop, temp) {
			push_event(.{kind = .File_Drop, text = path, time = time_now()});
		}
		win.DragFinish(hdrop);
		return 0;
	case win.WM_ERASEBKGND;
		return 1;
	} }
	return win.DefWindowProcW(hwnd, msg, wp, lp);
}

utf16_offset_to_byte :: (str: string, idx16: int) -> int {
	n := 0;
	for r, i: str {
		if n >= idx16 { return i; }
		n += ifx r >= 0x10000 then 2 else 1;
	}
	return len(str);
}
#scope_export

#scope_file static_id1: win.UINT; #scope_export

