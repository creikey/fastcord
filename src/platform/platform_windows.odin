#+build windows
package platform

import "base:runtime"
import "core:sync"
import "core:unicode/utf16"
import win "core:sys/windows"

foreign import user32 "system:User32.lib"
foreign import imm32 "system:Imm32.lib"

@(private = "file", default_calling_convention = "system")
foreign user32 {
	MsgWaitForMultipleObjectsEx :: proc(nCount: win.DWORD, pHandles: ^win.HANDLE, dwMilliseconds: win.DWORD, dwWakeMask: win.DWORD, dwFlags: win.DWORD) -> win.DWORD ---
	GetDoubleClickTime :: proc() -> win.UINT ---
}

@(private = "file")
COMPOSITIONFORM :: struct {
	dwStyle:      win.DWORD,
	ptCurrentPos: win.POINT,
	rcArea:       win.RECT,
}

@(private = "file", default_calling_convention = "system")
foreign imm32 {
	ImmGetContext :: proc(hwnd: win.HWND) -> rawptr ---
	ImmReleaseContext :: proc(hwnd: win.HWND, himc: rawptr) -> win.BOOL ---
	ImmGetCompositionStringW :: proc(himc: rawptr, index: win.DWORD, buf: rawptr, len: win.DWORD) -> win.LONG ---
	ImmSetCompositionWindow :: proc(himc: rawptr, form: ^COMPOSITIONFORM) -> win.BOOL ---
}

@(private = "file")
WM_FC_WAKE :: win.WM_USER + 1
@(private = "file")
TIMER_ANIM :: 1

@(private = "file")
Win :: struct {
	hwnd:            win.HWND,
	instance:        win.HINSTANCE,
	frame_wait:      win.HANDLE, // swap chain frame-latency waitable (set by gfx)
	high_surrogate:  u16,
	in_size_move:    bool,
	tracking_mouse:  bool,
	cursor_hidden:   bool,
	last_click_time: f64,
	last_click_pos:  [2]f32,
	last_click_btn:  Mouse_Button,
	click_count:     int,
	wake_posted:     bool,
	composing:       bool,
}

@(private = "file")
w: Win

native_window :: proc() -> rawptr {return rawptr(w.hwnd)}
native_view :: proc() -> rawptr {return rawptr(w.hwnd)}
native_metal_layer :: proc() -> rawptr {return nil}

// gfx registers the swap chain's frame-latency waitable object; wait_events
// waits on it (vsync pacing) when a frame was requested.
set_frame_wait_handle :: proc(h: rawptr) {w.frame_wait = win.HANDLE(h)}

@(private)
_init :: proc(title: string, width, height: int) -> bool {
	win.SetProcessDpiAwarenessContext(win.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)
	w.instance = win.HINSTANCE(win.GetModuleHandleW(nil))
	class_name: cstring16 = "fastcord"
	wc := win.WNDCLASSEXW {
		cbSize        = size_of(win.WNDCLASSEXW),
		style         = win.CS_HREDRAW | win.CS_VREDRAW | win.CS_OWNDC,
		lpfnWndProc   = wndproc,
		hInstance     = w.instance,
		hCursor       = win.LoadCursorA(nil, win.IDC_ARROW),
		lpszClassName = class_name,
	}
	if win.RegisterClassExW(&wc) == 0 do return false

	style := win.WS_OVERLAPPEDWINDOW
	dpi := win.GetDpiForSystem()
	scale := f32(dpi) / 96
	r := win.RECT{0, 0, i32(f32(width) * scale), i32(f32(height) * scale)}
	win.AdjustWindowRectExForDpi(&r, style, false, 0, dpi)
	w.hwnd = win.CreateWindowExW(0, class_name, win.utf8_to_wstring(title), style,
		win.CW_USEDEFAULT, win.CW_USEDEFAULT, r.right - r.left, r.bottom - r.top, nil, nil, w.instance, nil)
	if w.hwnd == nil do return false
	win.DragAcceptFiles(w.hwnd, true)
	update_size()
	update_refresh()
	win.ShowWindow(w.hwnd, win.SW_SHOW)
	win.UpdateWindow(w.hwnd)
	return true
}

@(private)
_shutdown :: proc() {
	if w.hwnd != nil do win.DestroyWindow(w.hwnd)
	w.hwnd = nil
}

@(private = "file")
update_size :: proc() {
	r: win.RECT
	win.GetClientRect(w.hwnd, &r)
	dpi := win.GetDpiForWindow(w.hwnd)
	s.scale = f32(dpi) / 96
	if s.scale <= 0 do s.scale = 1
	s.size = {f32(r.right - r.left) / s.scale, f32(r.bottom - r.top) / s.scale}
}

@(private = "file")
update_refresh :: proc() {
	dm: win.DEVMODEW
	dm.dmSize = size_of(dm)
	if win.EnumDisplaySettingsW(nil, win.ENUM_CURRENT_SETTINGS, &dm) && dm.dmDisplayFrequency > 1 {
		s.refresh_hz = f32(dm.dmDisplayFrequency)
	}
}

@(private)
_wake :: proc() {
	if sync.atomic_exchange(&w.wake_posted, true) do return
	win.PostMessageW(w.hwnd, WM_FC_WAKE, 0, 0)
}

@(private)
_wait :: proc(timeout: f64) {
	start := time_now()
	for {
		pump()
		animating := sync.atomic_load(&s.frame_requested)
		if s.quit do return
		if !animating && pending_count() > 0 do return
		ms: win.DWORD = win.INFINITE
		if timeout >= 0 {
			remaining := timeout - (time_now() - start)
			if remaining <= 0 do return
			ms = win.DWORD(remaining * 1000)
		}
		handles: [1]win.HANDLE
		n: win.DWORD = 0
		if animating {
			if w.frame_wait != nil {
				handles[0] = w.frame_wait
				n = 1
			} else {
				ms = min(ms, win.DWORD(1000 / max(s.refresh_hz, 30)))
			}
		}
		r := MsgWaitForMultipleObjectsEx(n, n > 0 ? &handles[0] : nil, ms, win.QS_ALLINPUT, 0x0004 /*MWMO_INPUTAVAILABLE*/)
		if animating {
			if n > 0 && r == win.WAIT_OBJECT_0 {
				pump()
				return // vsync: swap chain ready for the next frame
			}
			if n == 0 && r == win.WAIT_TIMEOUT {
				pump()
				return
			}
		}
		if r == win.WAIT_TIMEOUT && timeout >= 0 && time_now() - start >= timeout {
			pump()
			return
		}
	}
}

@(private = "file")
pump :: proc() {
	msg: win.MSG
	for win.PeekMessageW(&msg, nil, 0, 0, win.PM_REMOVE) {
		if msg.message == win.WM_QUIT {
			s.quit = true
			push_event({kind = .Quit, time = time_now()})
			continue
		}
		win.TranslateMessage(&msg)
		win.DispatchMessageW(&msg)
	}
}

@(private)
_clipboard_get :: proc(allocator: runtime.Allocator) -> string {
	if !win.OpenClipboard(w.hwnd) do return ""
	defer win.CloseClipboard()
	h := win.GetClipboardData(win.CF_UNICODETEXT)
	if h == nil do return ""
	p := ([^]u16)(win.GlobalLock(win.HGLOBAL(h)))
	if p == nil do return ""
	defer win.GlobalUnlock(win.HGLOBAL(h))
	n := 0
	for p[n] != 0 do n += 1
	out, _ := win.utf16_to_utf8(p[:n], allocator)
	return out
}

@(private)
_clipboard_set :: proc(str: string) {
	wide := win.utf8_to_utf16(str, context.temp_allocator)
	if !win.OpenClipboard(w.hwnd) do return
	defer win.CloseClipboard()
	win.EmptyClipboard()
	bytes := (len(wide) + 1) * 2
	h := win.GlobalAlloc(win.GMEM_MOVEABLE, uint(bytes))
	if h == nil do return
	p := ([^]u16)(win.GlobalLock(win.HGLOBAL(h)))
	copy(p[:len(wide)], wide)
	p[len(wide)] = 0
	win.GlobalUnlock(win.HGLOBAL(h))
	win.SetClipboardData(win.CF_UNICODETEXT, win.HANDLE(h))
}

@(private)
_apply_cursor :: proc() {
	if s.cursor == .Hidden {
		win.SetCursor(nil)
		return
	}
	id: uintptr
	switch s.cursor {
	case .Arrow, .Hidden: id = 32512
	case .Pointer:        id = 32649
	case .IBeam:          id = 32513
	case .Resize_H:       id = 32644
	case .Resize_V:       id = 32645
	case .Resize_NWSE:    id = 32642
	case .Resize_NESW:    id = 32643
	case .Move:           id = 32646
	case .Not_Allowed:    id = 32648
	case .Crosshair:      id = 32515
	}
	win.SetCursor(win.LoadCursorA(nil, cstring(rawptr(id))))
}

// ---------------------------------------------------------------------------

@(private = "file")
current_mods :: proc() -> Mods {
	m: Mods
	if win.GetKeyState(win.VK_SHIFT) < 0 do m += {.Shift}
	if win.GetKeyState(win.VK_CONTROL) < 0 do m += {.Ctrl}
	if win.GetKeyState(win.VK_MENU) < 0 do m += {.Alt}
	if win.GetKeyState(win.VK_LWIN) < 0 || win.GetKeyState(win.VK_RWIN) < 0 do m += {.Cmd}
	return m
}

@(private = "file")
map_vk :: proc(vk: win.WPARAM, lparam: win.LPARAM) -> Key {
	switch vk {
	case 'A' ..= 'Z': return Key(int(Key.A) + int(vk - 'A'))
	case '0' ..= '9': return Key(int(Key.N0) + int(vk - '0'))
	case win.VK_SPACE:  return .Space
	case win.VK_RETURN: return (lparam >> 24) & 1 != 0 ? .Keypad_Enter : .Enter
	case win.VK_TAB:    return .Tab
	case win.VK_BACK:   return .Backspace
	case win.VK_DELETE: return .Delete
	case win.VK_ESCAPE: return .Escape
	case win.VK_LEFT:   return .Left
	case win.VK_RIGHT:  return .Right
	case win.VK_UP:     return .Up
	case win.VK_DOWN:   return .Down
	case win.VK_HOME:   return .Home
	case win.VK_END:    return .End
	case win.VK_PRIOR:  return .Page_Up
	case win.VK_NEXT:   return .Page_Down
	case win.VK_SHIFT, win.VK_LSHIFT, win.VK_RSHIFT: return .Shift
	case win.VK_CONTROL, win.VK_LCONTROL, win.VK_RCONTROL: return .Ctrl
	case win.VK_MENU, win.VK_LMENU, win.VK_RMENU: return .Alt
	case win.VK_LWIN, win.VK_RWIN: return .Cmd
	case win.VK_CAPITAL: return .Caps_Lock
	case win.VK_F1 ..= win.VK_F12: return Key(int(Key.F1) + int(vk - win.VK_F1))
	case win.VK_OEM_MINUS:  return .Minus
	case win.VK_OEM_PLUS:   return .Equals
	case win.VK_OEM_4:      return .Left_Bracket
	case win.VK_OEM_6:      return .Right_Bracket
	case win.VK_OEM_5:      return .Backslash
	case win.VK_OEM_1:      return .Semicolon
	case win.VK_OEM_7:      return .Apostrophe
	case win.VK_OEM_COMMA:  return .Comma
	case win.VK_OEM_PERIOD: return .Period
	case win.VK_OEM_2:      return .Slash
	case win.VK_OEM_3:      return .Grave
	}
	return .None
}

@(private = "file")
lparam_pos :: proc(lp: win.LPARAM) -> [2]f32 {
	x := f32(win.GET_X_LPARAM(lp))
	y := f32(win.GET_Y_LPARAM(lp))
	return {x / s.scale, y / s.scale}
}

@(private = "file")
mouse_button_event :: proc(kind: Event_Kind, btn: Mouse_Button, lp: win.LPARAM) {
	pos := lparam_pos(lp)
	e := Event{kind = kind, button = btn, pos = pos, mods = current_mods(), time = time_now()}
	if kind == .Mouse_Down {
		now := time_now()
		dbl := f64(GetDoubleClickTime()) / 1000
		d := pos - w.last_click_pos
		if btn == w.last_click_btn && now - w.last_click_time <= dbl && d.x * d.x + d.y * d.y < 16 {
			w.click_count += 1
		} else {
			w.click_count = 1
		}
		w.last_click_time = now
		w.last_click_pos = pos
		w.last_click_btn = btn
		win.SetCapture(w.hwnd)
	} else {
		win.ReleaseCapture()
	}
	e.click_count = w.click_count
	push_event(e)
}

@(private = "file")
update_ime_window :: proc() {
	himc := ImmGetContext(w.hwnd)
	if himc == nil do return
	defer ImmReleaseContext(w.hwnd, himc)
	cf := COMPOSITIONFORM{dwStyle = 0x0002 /*CFS_POINT*/, ptCurrentPos = {i32(s.ime_rect[0] * s.scale), i32((s.ime_rect[1] + s.ime_rect[3]) * s.scale)}}
	ImmSetCompositionWindow(himc, &cf)
}

@(private = "file")
wndproc :: proc "system" (hwnd: win.HWND, msg: win.UINT, wp: win.WPARAM, lp: win.LPARAM) -> win.LRESULT {
	context = s.ctx
	switch msg {
	case WM_FC_WAKE:
		sync.atomic_store(&w.wake_posted, false)
		return 0
	case win.WM_CLOSE:
		s.quit = true
		push_event({kind = .Quit, time = time_now()})
		return 0
	case win.WM_SIZE:
		update_size()
		push_event({kind = .Resize, pos = s.size, time = time_now()})
		if w.in_size_move do run_frame_callback()
		return 0
	case win.WM_DPICHANGED:
		r := (^win.RECT)(uintptr(lp))
		win.SetWindowPos(hwnd, nil, r.left, r.top, r.right - r.left, r.bottom - r.top, win.SWP_NOZORDER | win.SWP_NOACTIVATE)
		update_size()
		push_event({kind = .Resize, pos = s.size, time = time_now()})
		return 0
	case win.WM_ENTERSIZEMOVE:
		w.in_size_move = true
		win.SetTimer(hwnd, TIMER_ANIM, 1, nil)
		return 0
	case win.WM_EXITSIZEMOVE:
		w.in_size_move = false
		win.KillTimer(hwnd, TIMER_ANIM)
		return 0
	case win.WM_TIMER:
		if wp == TIMER_ANIM && w.in_size_move && sync.atomic_load(&s.frame_requested) do run_frame_callback()
		return 0
	case win.WM_SETFOCUS:
		push_event({kind = .Focus_Gained, time = time_now()})
		return 0
	case win.WM_KILLFOCUS:
		push_event({kind = .Focus_Lost, time = time_now()})
		return 0
	case win.WM_SETCURSOR:
		if win.LOWORD(win.DWORD(lp)) == win.HTCLIENT {
			_apply_cursor()
			return 1
		}
	case win.WM_KEYDOWN, win.WM_SYSKEYDOWN:
		k := map_vk(wp, lp)
		push_event({kind = .Key_Down, key = k, mods = current_mods(), is_repeat = (lp >> 30) & 1 != 0, time = time_now()})
		if msg == win.WM_SYSKEYDOWN && wp == win.VK_F4 do break // let Alt+F4 through
		if msg == win.WM_SYSKEYDOWN do return 0
		return 0
	case win.WM_KEYUP, win.WM_SYSKEYUP:
		push_event({kind = .Key_Up, key = map_vk(wp, lp), mods = current_mods(), time = time_now()})
		return 0
	case win.WM_CHAR:
		c := u16(wp)
		if c >= 0xD800 && c <= 0xDBFF {
			w.high_surrogate = c
			return 0
		}
		buf: [2]u16
		n := 0
		if c >= 0xDC00 && c <= 0xDFFF && w.high_surrogate != 0 {
			buf = {w.high_surrogate, c}
			n = 2
		} else {
			buf[0] = c
			n = 1
		}
		w.high_surrogate = 0
		if n == 1 && (c < 0x20 || c == 0x7f) do return 0
		mods := current_mods()
		if .Ctrl in mods && .Alt not_in mods do return 0 // ctrl shortcuts are Key_Down only (AltGr = ctrl+alt types text)
		utf8buf: [8]u8
		l := utf16.decode_to_utf8(utf8buf[:], buf[:n])
		push_event({kind = .Text, text = string(utf8buf[:l]), time = time_now()})
		return 0
	case win.WM_IME_STARTCOMPOSITION:
		update_ime_window()
		w.composing = true
	case win.WM_IME_COMPOSITION:
		update_ime_window()
		if lp & 0x0008 /*GCS_COMPSTR*/ != 0 {
			himc := ImmGetContext(hwnd)
			if himc != nil {
				bytes := ImmGetCompositionStringW(himc, 0x0008, nil, 0)
				text := ""
				if bytes > 0 {
					wbuf := make([]u16, bytes / 2, context.temp_allocator)
					ImmGetCompositionStringW(himc, 0x0008, raw_data(wbuf), win.DWORD(bytes))
					text, _ = win.utf16_to_utf8(wbuf, context.temp_allocator)
				}
				cursor := ImmGetCompositionStringW(himc, 0x0080 /*GCS_CURSORPOS*/, nil, 0)
				ImmReleaseContext(hwnd, himc)
				cb := utf16_offset_to_byte(text, int(cursor))
				push_event({kind = .Composition, text = text, composition_sel = {cb, cb}, time = time_now()})
			}
		}
		// GCS_RESULTSTR arrives as WM_CHAR via DefWindowProc
	case win.WM_IME_ENDCOMPOSITION:
		if w.composing {
			w.composing = false
			push_event({kind = .Composition, time = time_now()})
		}
	case win.WM_MOUSEMOVE:
		if !w.tracking_mouse {
			tme := win.TRACKMOUSEEVENT{cbSize = size_of(win.TRACKMOUSEEVENT), dwFlags = win.TME_LEAVE, hwndTrack = hwnd}
			win.TrackMouseEvent(&tme)
			w.tracking_mouse = true
		}
		push_event({kind = .Mouse_Move, pos = lparam_pos(lp), mods = current_mods(), time = time_now()})
		return 0
	case win.WM_MOUSELEAVE:
		w.tracking_mouse = false
		push_event({kind = .Mouse_Leave, time = time_now()})
		return 0
	case win.WM_LBUTTONDOWN: mouse_button_event(.Mouse_Down, .Left, lp); return 0
	case win.WM_LBUTTONUP:   mouse_button_event(.Mouse_Up, .Left, lp); return 0
	case win.WM_RBUTTONDOWN: mouse_button_event(.Mouse_Down, .Right, lp); return 0
	case win.WM_RBUTTONUP:   mouse_button_event(.Mouse_Up, .Right, lp); return 0
	case win.WM_MBUTTONDOWN: mouse_button_event(.Mouse_Down, .Middle, lp); return 0
	case win.WM_MBUTTONUP:   mouse_button_event(.Mouse_Up, .Middle, lp); return 0
	case win.WM_XBUTTONDOWN: mouse_button_event(.Mouse_Down, win.HIWORD(win.DWORD(wp)) == 1 ? .X1 : .X2, lp); return 1
	case win.WM_XBUTTONUP:   mouse_button_event(.Mouse_Up, win.HIWORD(win.DWORD(wp)) == 1 ? .X1 : .X2, lp); return 1
	case win.WM_MOUSEWHEEL, win.WM_MOUSEHWHEEL:
		delta := f32(win.GET_WHEEL_DELTA_WPARAM(wp)) / 120 * 40 // Chrome: 40px per notch
		pt := win.POINT{win.GET_X_LPARAM(lp), win.GET_Y_LPARAM(lp)}
		win.ScreenToClient(hwnd, &pt)
		e := Event{kind = .Scroll, pos = {f32(pt.x) / s.scale, f32(pt.y) / s.scale}, mods = current_mods(), time = time_now()}
		if msg == win.WM_MOUSEWHEEL do e.delta.y = delta
		else do e.delta.x = -delta
		push_event(e)
		return 0
	case win.WM_DROPFILES:
		hdrop := win.HDROP(wp)
		n := win.DragQueryFileW(hdrop, 0xFFFFFFFF, nil, 0)
		for i in 0 ..< n {
			l := win.DragQueryFileW(hdrop, i, nil, 0)
			buf := make([]u16, l + 1, context.temp_allocator)
			win.DragQueryFileW(hdrop, i, raw_data(buf), l + 1)
			path, _ := win.utf16_to_utf8(buf[:l], context.temp_allocator)
			push_event({kind = .File_Drop, text = path, time = time_now()})
		}
		win.DragFinish(hdrop)
		return 0
	case win.WM_ERASEBKGND:
		return 1
	}
	return win.DefWindowProcW(hwnd, msg, wp, lp)
}

@(private = "file")
utf16_offset_to_byte :: proc(str: string, idx16: int) -> int {
	n := 0
	for r, i in str {
		if n >= idx16 do return i
		n += r >= 0x10000 ? 2 : 1
	}
	return len(str)
}
