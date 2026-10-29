native_window :: () -> *void { return w.hwnd; }
native_metal_layer :: () -> *void { return null; }

// WDA_EXCLUDEFROMCAPTURE (Electron's setContentProtection) or WDA_NONE.
set_capture_hidden :: (hidden: bool) {
    if w.hwnd SetWindowDisplayAffinity(w.hwnd, xx ifx hidden then 0x11 else 0);
}

// gfx registers the swap chain's frame-latency waitable object; every rendered frame waits on it once (vsync pacing).
set_frame_wait_handle :: (h: *void) { w.frame_wait = h; }

// True while drawing the frame for a WM_SIZE inside the modal resize loop.
is_size_frame :: () -> bool { return w.size_frame; }

// A dropped Present never retires, so the waitable won't signal for it; the next frame must not wait on it.
present_dropped :: () { w.frame_ready = true; }

// True when Windows' app mode is dark (HKCU\...\Themes\Personalize AppsUseLightTheme = 0). ok is false
// headless or when unset.
system_dark_mode :: () -> dark: bool, ok: bool {
    if s.headless return false, false;
    v, n: u32 = 0, size_of(u32);
    st := reg.RegGetValueA(reg.HKEY_CURRENT_USER, "Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize", "AppsUseLightTheme", reg.RRF_RT_REG_DWORD, null, *v, *n);
    if st != 0 return false, false;
    return v == 0, true;
}

// What Chromium's media queries read on Windows: client-area animations off -> prefers-reduced-motion;
// High Contrast -> forced-colors (and prefers-contrast: more). No inverted-colors.
system_a11y :: () -> System_A11y {
    a: System_A11y;
    if s.headless return a;
    anim: s32 = 1;
    if SystemParametersInfoW(SPI_GETCLIENTAREAANIMATION, 0, *anim, 0) a.reduce_motion = anim == 0;
    HIGHCONTRASTW :: struct { cbSize: u32; dwFlags: u32; lpszDefaultScheme: *u16; }
    hc := HIGHCONTRASTW.{cbSize = size_of(HIGHCONTRASTW)};
    if SystemParametersInfoW(SPI_GETHIGHCONTRAST, size_of(HIGHCONTRASTW), *hc, 0) && (hc.dwFlags & 1 /*HCF_HIGHCONTRASTON*/) {
        a.forced_colors = true;
        a.contrast_more = true;
    }
    return a;
}

// Modal "open file" dialog (IFileOpenDialog, on the UI thread's OLE apartment). Returns absolute paths
// (empty if cancelled).
open_file_dialog :: (allow_multiple := true, allocator := context.allocator) -> []string {
    if s.headless return .[];
    CLSID_FileOpenDialog := win.GUID.{0xDC1C5A9C, 0xE88A, 0x4DDE, .[0xA5, 0xA1, 0x60, 0xF8, 0x2A, 0x20, 0xAE, 0xF7]};
    IID_IFileOpenDialog := win.GUID.{0xD57C7288, 0xD4AD, 0x4768, .[0xBE, 0x02, 0x9D, 0x96, 0x95, 0x32, 0xD9, 0x60]};
    HR :: win.HRESULT;
    dlg, items: *void;
    defer { release(items); release(dlg); }
    // IFileDialog::GetOptions (10), SetOptions (9); IModalWindow::Show (3); IFileOpenDialog::GetResults (27)
    opts: u32;
    if CoCreateInstance(*CLSID_FileOpenDialog, null, 1 /*CLSCTX_INPROC_SERVER*/, *IID_IFileOpenDialog, *dlg) < 0 ||
        vt(dlg, 10, #type (*void, *u32) -> HR #c_call)(dlg, *opts) < 0 return .[];
    opts |= 0x40 /*FOS_FORCEFILESYSTEM*/ | 0x1000 /*FOS_FILEMUSTEXIST*/;
    if allow_multiple opts |= 0x200; // FOS_ALLOWMULTISELECT
    if vt(dlg, 9, #type (*void, u32) -> HR #c_call)(dlg, opts) < 0 ||
        vt(dlg, 3, #type (*void, win.HWND) -> HR #c_call)(dlg, w.hwnd) < 0 || // cancelled: ERROR_CANCELLED
        vt(dlg, 27, #type (*void, **void) -> HR #c_call)(dlg, *items) < 0 return .[];
    // IShellItemArray::GetCount (7), GetItemAt (8); IShellItem::GetDisplayName (5)
    n: u32;
    if vt(items, 7, #type (*void, *u32) -> HR #c_call)(items, *n) < 0 return .[];
    out: [..]string;
    out.allocator = allocator;
    for i: 0..cast(s64) n - 1 {
        item: *void;
        p: *u16;
        if vt(items, 8, #type (*void, u32, **void) -> HR #c_call)(items, xx i, *item) < 0 continue;
        if vt(item, 5, #type (*void, u32, **u16) -> HR #c_call)(item, 0x80058000 /*SIGDN_FILESYSPATH*/, *p) >= 0 {
            array_add(*out, utf16_to_utf8(p, -1, allocator));
            CoTaskMemFree(p);
        }
        release(item);
    }
    return out;
}

// A notification through the tray icon's balloon, which Windows 10 and 11 show as a toast (Action Center,
// Focus Assist) with no AppUserModelID or Start menu shortcut. Clicking it opens the window. Each one replaces
// the last, so `id` is unused. The app plays the notification sound itself.
notify_show :: (title: string, body: string, id: string) -> bool {
    if s.headless || !w.tray return false;
    nid := NOTIFYICONDATAW.{cbSize = size_of(NOTIFYICONDATAW), hWnd = w.hwnd, uID = 1, uFlags = NIF_INFO};
    nid.dwInfoFlags = NIIF_USER | NIIF_LARGE_ICON | NIIF_NOSOUND;
    nid.hBalloonIcon = w.big_icon;
    copy_wide :: (dst: []u16, str: string) {
        src := wide(ifx str then str else " "); // an empty szInfo removes the balloon
        n := 0;
        while src[n] && n < dst.count - 1 n += 1;
        if n == dst.count - 1 && n > 0 && src[n - 1] >= 0xD800 && src[n - 1] < 0xDC00 n -= 1; // half a pair
        memcpy(dst.data, src, n * 2);
        dst[n] = 0;
    }
    copy_wide(nid.szInfoTitle, title);
    copy_wide(nid.szInfo, body);
    return Shell_NotifyIconW(NIM_MODIFY, *nid) != 0;
}

// Puts a red dot on the tray icon and on the taskbar button (ITaskbarList3 overlay) while text isn't ""
// (unread mentions).
set_badge :: (text: string) {
    if s.headless || !w.small_icon return;
    if w.tray_badge_icon DestroyIcon(w.tray_badge_icon);
    w.tray_badge_icon = ifx text then badge_icon(w.small_icon) else null;
    if w.tray tray_notify(NIM_MODIFY);
    if !w.taskbar {
        CLSID_TaskbarList := win.GUID.{0x56FDF344, 0xFD6D, 0x11D0, .[0x95, 0x8A, 0x00, 0x60, 0x97, 0xC9, 0xA0, 0x90]};
        IID_ITaskbarList3 := win.GUID.{0xEA1AFB91, 0x9E28, 0x4B86, .[0x90, 0xE9, 0x9E, 0x9F, 0x8A, 0x5E, 0xEF, 0xAF]};
        if CoCreateInstance(*CLSID_TaskbarList, null, 1 /*CLSCTX_INPROC_SERVER*/, *IID_ITaskbarList3, *w.taskbar) < 0 return;
        vt(w.taskbar, 3, #type (*void) -> win.HRESULT #c_call)(w.taskbar); // HrInit
    }
    dot := ifx text then badge_icon(null) else null;
    defer if dot DestroyIcon(dot); // the taskbar keeps its own copy
    vt(w.taskbar, 18, #type (*void, win.HWND, win.HICON, *u16) -> win.HRESULT #c_call)(w.taskbar, w.hwnd, dot, ifx text then wide("Unread mentions") else null); // SetOverlayIcon
}

// Opens a URL in the user's default browser. ShellExecute runs whatever it is given (files, UNC
// paths, protocol handlers): the app's `open_url` checks the scheme.
open_url :: (url: string) {
    ShellExecuteW(null, wide("open"), wide(url), null, null, win.SW_SHOWNORMAL);
}

// The user's Downloads folder (wherever they moved it), "" if Windows has none.
downloads_dir :: (allocator := temp) -> string {
    FOLDERID_Downloads := win.GUID.{0x374DE290, 0x123F, 0x4565, .[0x91, 0x64, 0x39, 0xC4, 0x92, 0x5E, 0x46, 0x7B]};
    p: *u16;
    if SHGetKnownFolderPath(*FOLDERID_Downloads, 0, null, *p) < 0 return "";
    defer CoTaskMemFree(p);
    return utf16_to_utf8(p, -1, allocator);
}

// The window has no system title bar or border (WM_NCCALCSIZE gives it all to the content). The app draws
// its own title bar and says what Windows should do at a point (content coordinates): Caption drags the
// window, double-click maximizes and right-click opens the system menu; Maximize shows the snap layouts.
Window_Hit :: enum u8 { Client; Caption; Maximize; }
set_window_hit_callback :: (cb: (p: Vector2) -> Window_Hit) { w.hit_callback = cb; }

window_minimize :: () { win.ShowWindow(w.hwnd, win.SW_MINIMIZE); }
window_maximized :: () -> bool { return w.hwnd && IsZoomed(w.hwnd) != 0; }
window_toggle_maximize :: () { win.ShowWindow(w.hwnd, xx ifx window_maximized() then win.SW_RESTORE else win.SW_MAXIMIZE); }
window_close :: () { PostMessageW(w.hwnd, win.WM_CLOSE, 0, 0); }
// Brings the window to the front, also from the tray.
window_show :: () {
    win.ShowWindow(w.hwnd, xx ifx IsIconic(w.hwnd) then win.SW_RESTORE else win.SW_SHOW);
    SetForegroundWindow(w.hwnd);
}

// The window's restored rect (screen pixels; also while maximized or minimized) and whether it is maximized.
window_placement :: () -> Window_Placement, bool {
    wp := WINDOWPLACEMENT.{length = size_of(WINDOWPLACEMENT)};
    if !w.hwnd || GetWindowPlacement(w.hwnd, *wp) == 0 return .{}, false;
    r := wp.rcNormalPosition;
    maxed := IsZoomed(w.hwnd) != 0 || (IsIconic(w.hwnd) != 0 && (wp.flags & WPF_RESTORETOMAXIMIZED) != 0);
    return .{r.left, r.top, r.right - r.left, r.bottom - r.top, maxed}, true;
}

// Before init: where the window opens. Windows moves a rect that is off every monitor back onto one.
window_placement_restore :: (p: Window_Placement) {
    w.restore = p;
    w.has_restore = true;
}

// Makes this exe the per-user handler of scheme:// links (HKCU\Software\Classes). With if_free, only when no
// other app has it (the official client registers discord://) or it already names a fastcord.
url_handler_register :: (scheme: string, if_free := false) {
    key := tprint("Software\\Classes\\%", scheme);
    command := tprint("Software\\Classes\\%\\shell\\open\\command", scheme);
    if if_free {
        buf: [1024]u8;
        n: u32 = buf.count;
        if reg.RegGetValueA(reg.HKEY_CURRENT_USER, temp_c_string(command), null, reg.RRF_RT_REG_SZ, null, buf.data, *n) == 0 {
            if !contains(to_lower_copy(string.{n, buf.data},, temp), "fastcord") return;
        } else if reg.RegGetValueA(reg.HKEY_CURRENT_USER, temp_c_string(key), null, 0xffff, null, null, null) == 0 return;
    }
    reg_set(key, "", tprint("URL:% link", scheme));
    reg_set(key, "URL Protocol", "");
    reg_set(command, "", tprint("% \"\%1\"", exe_quoted()));
}

// Open at login: a value in HKCU's Run key, as the official client's "Automatically open Discord" sets.
open_at_login :: () -> bool {
    if s.headless return s.headless_login;
    return reg.RegGetValueA(reg.HKEY_CURRENT_USER, RUN_KEY, "fastcord", reg.RRF_RT_REG_SZ, null, null, null) == 0;
}

set_open_at_login :: (on: bool) {
    if s.headless { s.headless_login = on; return; }
    if on { reg_set(RUN_KEY, "fastcord", exe_quoted()); return; }
    k: win.HKEY;
    if RegCreateKeyExW(reg.HKEY_CURRENT_USER, wide(RUN_KEY), 0, null, 0, reg.KEY_WRITE, null, *k, null) != 0 return;
    RegDeleteValueW(k, wide("fastcord"));
    reg.RegCloseKey(k);
}

RUN_KEY :: "Software\\Microsoft\\Windows\\CurrentVersion\\Run";
exe_quoted :: () -> string { return tprint("\"%\"", replace(system.get_path_of_running_executable(), "/", "\\",, temp)); }

reg_set :: (path: string, name: string, value: string) {
    k: win.HKEY;
    if RegCreateKeyExW(reg.HKEY_CURRENT_USER, wide(path), 0, null, 0, reg.KEY_WRITE, null, *k, null) != 0 return;
    v, _, bytes := utf8_to_wide(value,, temp);
    zero: u16;
    if !v v = *zero;
    RegSetValueExW(k, ifx name then wide(name) else null, 0, REG_SZ, xx v, xx (bytes + 2));
    reg.RegCloseKey(k);
}

RegCreateKeyExW :: (key: win.HKEY, sub: *u16, reserved: u32, class: *u16, options: u32, sam: u32, attrs: *void, out: *win.HKEY, disposition: *u32) -> s32 #foreign advapi32;
RegDeleteValueW :: (key: win.HKEY, name: *u16) -> s32 #foreign advapi32;
RegSetValueExW :: (key: win.HKEY, name: *u16, reserved: u32, type: u32, data: *u8, bytes: u32) -> s32 #foreign advapi32;
REG_SZ :: 1;
advapi32 :: #system_library "advapi32";

#scope_module

// A named mutex says who is first; WM_COPYDATA to its window (whose class is named after the <state>)
// carries the message.
os_instance_claim :: (name: string, message: string) -> bool {
    w.class_name = copy_string(name);
    mutex := CreateMutexW(null, 0, wide(tprint("Local\\%", name)));
    if !mutex || win.GetLastError() != ERROR_ALREADY_EXISTS return true; // first: the handle stays open
    win.CloseHandle(mutex);
    for 1..30 { // it may still be creating its window
        hwnd := FindWindowW(wide(name), null);
        if hwnd {
            pid: u32;
            GetWindowThreadProcessId(hwnd, *pid);
            AllowSetForegroundWindow(pid); // we are the foreground launch; let it take the foreground
            cds := COPYDATASTRUCT.{dwData = COPYDATA_OPEN, cbData = xx message.count, lpData = message.data};
            result: u64;
            SendMessageTimeoutW(hwnd, WM_COPYDATA, 0, cast(win.LPARAM) *cds, SMTO_ABORTIFHUNG, 5000, *result);
            return false;
        }
        win.Sleep(100);
    }
    return false;
}

CreateMutexW :: (attrs: *void, initial_owner: s32, name: *u16) -> *void #foreign kernel32;
FindWindowW :: (class: *u16, title: *u16) -> win.HWND #foreign user32;
GetWindowThreadProcessId :: (hwnd: win.HWND, pid: *u32) -> u32 #foreign user32;
AllowSetForegroundWindow :: (pid: u32) -> s32 #foreign user32;
SendMessageTimeoutW :: (hwnd: win.HWND, msg: u32, wp: win.WPARAM, lp: win.LPARAM, flags: u32, timeout_ms: u32, result: *u64) -> s64 #foreign user32;
COPYDATASTRUCT :: struct { dwData: u64; cbData: u32; lpData: *void; }
WM_COPYDATA :: 0x4A;
SMTO_ABORTIFHUNG :: 2;
ERROR_ALREADY_EXISTS :: 183;
COPYDATA_OPEN :: 0x4643_4f50; // 'FCOP'

SetConsoleCtrlHandler :: (handler: (ctrl: u32) -> s32 #c_call, add: s32) -> s32 #foreign kernel32;

quit_on_signals :: () {
    SetConsoleCtrlHandler((ctrl: u32) -> s32 #c_call {
        c := s.ctx; push_context,defer_pop c;
        s.quit = true;
        push_event(.{kind = .Quit, time = time_now()});
        request_frame();
        // Close, log off and shutdown end the process when this returns: give the exit work time.
        if ctrl >= 2 win.Sleep(10_000);
        return 1;
    }, 1);
}

os_init ::(title: string, width: int, height: int) -> bool {
    SetProcessDpiAwarenessContext(win.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    w.instance = win.GetModuleHandleW(null);
    dpi := GetDpiForSystem();
    // The exe's icon (build.jai embeds it as resource 2) goes on every window this thread creates, as Happenlance does.
    big := GetSystemMetricsForDpi(SM_CXICON, dpi);
    w.small_size = GetSystemMetricsForDpi(SM_CXSMICON, dpi);
    w.big_icon = LoadImageW(w.instance, cast(*u16) 2, IMAGE_ICON, big, big, 0);
    w.small_icon = LoadImageW(w.instance, cast(*u16) 2, IMAGE_ICON, w.small_size, w.small_size, 0);
    w.icon_hook = SetWindowsHookExW(WH_CBT, xx icon_hook, null, win.GetCurrentThreadId());
    class_name := wide(ifx w.class_name then w.class_name else "fastcord");
    wc := win.WNDCLASSEXW.{
        cbSize = size_of(win.WNDCLASSEXW),
        style = win.CS_HREDRAW | win.CS_VREDRAW | win.CS_OWNDC,
        lpfnWndProc = xx wndproc,
        hInstance = w.instance,
        hCursor = win.LoadCursorA(null, win.IDC_ARROW),
        hbrBackground = win.GetStockObject(win.BLACK_BRUSH),
        lpszClassName = class_name,
    };
    if win.RegisterClassExW(*wc) == 0 return false;

    // WS_OVERLAPPEDWINDOW keeps snapping, the min/max animations and the system menu; WM_NCCALCSIZE makes
    // the whole window content, so the window is the content size.
    scale := cast(float32) dpi / 96;
    CW_USEDEFAULT :: cast,no_check(s32) 0x8000_0000;
    w.hwnd = win.CreateWindowExW(0, class_name, wide(title), win.WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, xx (width * scale), xx (height * scale), null, null, w.instance, null);
    if !w.hwnd return false;
    // Without a frame DWM drops the shadow; a 1px frame extended under the content brings it back.
    margins := MARGINS.{1, 1, 1, 1};
    DwmExtendFrameIntoClientArea(w.hwnd, *margins);
    win.SetWindowPos(w.hwnd, null, 0, 0, 0, 0, win.SWP_FRAMECHANGED | win.SWP_NOMOVE | win.SWP_NOSIZE | win.SWP_NOZORDER | win.SWP_NOACTIVATE);
    // IDropTarget gives drag enter/leave (the "Upload to #channel" overlay); WM_DROPFILES is the fallback.
    if !drop_target_register(w.hwnd) win.DragAcceptFiles(w.hwnd, .TRUE);
    show := win.SW_SHOW;
    if w.has_restore && w.restore.width > 0 && w.restore.height > 0 {
        r := w.restore;
        wp := WINDOWPLACEMENT.{length = size_of(WINDOWPLACEMENT), showCmd = win.SW_HIDE};
        wp.rcNormalPosition = .{r.x, r.y, r.x + r.width, r.y + r.height};
        SetWindowPlacement(w.hwnd, *wp);
        if r.maximized show = win.SW_SHOWMAXIMIZED;
    }
    update_size();
    update_refresh();
    win.ShowWindow(w.hwnd, xx show);
    // The first ShowWindow may take the launcher's STARTUPINFO show command instead of ours.
    if show == win.SW_SHOWMAXIMIZED && IsZoomed(w.hwnd) == 0 win.ShowWindow(w.hwnd, win.SW_SHOWMAXIMIZED);
    win.UpdateWindow(w.hwnd);
    w.taskbar_created = RegisterWindowMessageW(wide("TaskbarCreated"));
    w.tray = tray_notify(NIM_ADD);
    return true;
}

os_shutdown :: () {
    if w.tray tray_notify(NIM_DELETE);
    w.tray = false;
    if w.hwnd && w.drop_registered RevokeDragDrop(w.hwnd);
    release(w.taskbar);
    w.taskbar = null;
    if w.hwnd win.DestroyWindow(w.hwnd);
    if w.icon_hook UnhookWindowsHookEx(w.icon_hook);
    for win.HICON.[w.big_icon, w.small_icon, w.tray_badge_icon] if it DestroyIcon(it);
    w.icon_hook, w.big_icon, w.small_icon, w.tray_badge_icon = null, null, null, null;
    w.hwnd = null;
}

os_wake :: () {
    if atomic_exchange(*w.wake_posted, true) return;
    PostMessageW(w.hwnd, WM_FC_WAKE, 0, 0);
}

// Each Present signals the waitable once. A frame that skips the wait leaves a signal behind, so later
// waits return early and frames queue up behind the GPU, adding a frame of input lag.
os_frame_wait :: () {
    if w.frame_ready {
        w.frame_ready = false;
        return;
    }
    if !w.frame_wait || IsIconic(w.hwnd) return;
    win.WaitForSingleObject(w.frame_wait, 100);
}

os_wait :: (timeout: float64) {
    start := time_now();
    while true {
        pump();
        animating := atomic_load(*s.frame_requested);
        if s.quit return;
        if !animating && pending_count() > 0 return;
        if animating && w.frame_ready return;
        ms := win.INFINITE;
        if timeout >= 0 {
            remaining := timeout - (time_now() - start);
            if remaining <= 0 return;
            ms = cast(u32) (remaining * 1000);
        }
        handle: *void;
        n: u32;
        if animating {
            if w.frame_wait {
                handle = w.frame_wait;
                n = 1;
            } else {
                ms = min(ms, cast(u32) (1000 / max(s.refresh_hz, 30)));
            }
        }
        r := MsgWaitForMultipleObjectsEx(n, ifx n then *handle else null, ms, QS_ALLINPUT, 0x0004 /*MWMO_INPUTAVAILABLE*/);
        // vsync (the swap chain is ready for the next frame), the frame timer, or the timeout
        if (animating && ((n && r == win.WAIT_OBJECT_0) || (!n && r == win.WAIT_TIMEOUT))) ||
           (r == win.WAIT_TIMEOUT && timeout >= 0 && time_now() - start >= timeout) {
            w.frame_ready = n && r == win.WAIT_OBJECT_0;
            pump();
            return;
        }
    }
}

os_clipboard_get :: (allocator: Allocator) -> string {
    if win.OpenClipboard(w.hwnd) == .FALSE return "";
    defer win.CloseClipboard();
    h := win.GetClipboardData(win.CF_UNICODETEXT);
    if !h return "";
    p := cast(*u16) win.GlobalLock(h);
    if !p return "";
    defer win.GlobalUnlock(h);
    return utf16_to_utf8(p, -1, allocator);
}

os_clipboard_set :: (str: string) {
    wstr, _, bytes := utf8_to_wide(str,, temp);
    if win.OpenClipboard(w.hwnd) == .FALSE return;
    defer win.CloseClipboard();
    win.EmptyClipboard();
    h := win.GlobalAlloc(win.GMEM_MOVEABLE, xx (bytes + 2));
    if !h return;
    p := cast(*u8) win.GlobalLock(h);
    memcpy(p, wstr, bytes);
    p[bytes] = 0;
    p[bytes + 1] = 0;
    win.GlobalUnlock(h);
    win.SetClipboardData(win.CF_UNICODETEXT, h);
}

os_clipboard_kind :: () -> Clipboard_Kind {
    if IsClipboardFormatAvailable(win.CF_HDROP) return .Files;
    if IsClipboardFormatAvailable(cf_png()) || IsClipboardFormatAvailable(win.CF_DIBV5) || IsClipboardFormatAvailable(win.CF_DIB) return .Image;
    if IsClipboardFormatAvailable(win.CF_UNICODETEXT) return .Text;
    return .None;
}

// "PNG" (browsers, Office) as is; else CF_DIBV5 / CF_DIB (screenshots) encoded as PNG by WIC.
os_clipboard_image :: (allocator: Allocator) -> []u8, bool {
    if !open_clipboard_any() return .[], false;
    defer win.CloseClipboard();
    b := global_bytes(win.GetClipboardData(cf_png()), allocator);
    if b.count return b, true;
    dib := global_bytes(win.GetClipboardData(win.CF_DIBV5), temp);
    if !dib.count dib = global_bytes(win.GetClipboardData(win.CF_DIB), temp);
    rgba, width, height, ok := dib_to_rgba(dib, temp);
    if !ok return .[], false;
    png := wic_png(rgba, width, height, allocator);
    return png, png.count > 0;
}

// CF_DIBV5 (straight alpha; Windows makes CF_DIB from it) and "PNG", which keeps alpha for browsers and
// Office. Decoded by imagefmt (first frame). Worker thread.
os_clipboard_set_image :: (data: []u8) {
    img, err := imagefmt.decode_first_frame(data, temp, max_pixels = 16 << 20);
    if err != .None return;
    px := img.frames[0].pixels;
    dib := win.GlobalAlloc(win.GMEM_MOVEABLE, xx (124 + px.count));
    if !dib return;
    p := cast(*u8) win.GlobalLock(dib);
    rgba_to_dibv5(px, img.width, img.height, .{124 + px.count, p});
    win.GlobalUnlock(dib);
    png := ifx img.format == .PNG then data else wic_png(px, img.width, img.height, temp);
    hpng := ifx png.count then win.GlobalAlloc(win.GMEM_MOVEABLE, xx png.count) else null;
    if hpng {
        memcpy(win.GlobalLock(hpng), png.data, png.count);
        win.GlobalUnlock(hpng);
    }
    if !open_clipboard_any(w.hwnd) { GlobalFree(dib); GlobalFree(hpng); return; }
    defer win.CloseClipboard();
    win.EmptyClipboard();
    win.SetClipboardData(win.CF_DIBV5, dib); // the clipboard owns both handles now
    if hpng win.SetClipboardData(cf_png(), hpng);
}

os_clipboard_files :: (allocator: Allocator) -> []string {
    if !open_clipboard_any() return .[];
    defer win.CloseClipboard();
    h := win.GetClipboardData(win.CF_HDROP);
    if !h return .[];
    return hdrop_paths(h, allocator);
}

os_apply_cursor :: () {
    if s.cursor == .Hidden {
        win.SetCursor(null);
        return;
    }
    id: int;
    if s.cursor == {
        case .Pointer;     id = 32649;
        case .IBeam;       id = 32513;
        case .Resize_H;    id = 32644;
        case .Resize_V;    id = 32645;
        case .Resize_NWSE; id = 32642;
        case .Resize_NESW; id = 32643;
        case .Move;        id = 32646;
        case .Not_Allowed; id = 32648;
        case .Crosshair;   id = 32515;
        case;              id = 32512; // arrow
    }
    win.SetCursor(win.LoadCursorA(null, cast(*u8) id));
}

#scope_file

win :: #import "Windows";
reg :: #import "Windows_Registry";
system :: #import "System";
imagefmt :: #import "imagefmt";
#import "Windows_Utf8";

user32 :: #system_library "user32";
kernel32 :: #system_library "kernel32";
imm32 :: #system_library "imm32";
ole32 :: #system_library "ole32";
shell32 :: #system_library "shell32";
gdi32 :: #system_library "gdi32";
dwmapi :: #system_library "dwmapi";

// Not in Jai's Windows module. BOOL results are s32 here so they test as ints.
MsgWaitForMultipleObjectsEx :: (nCount: u32, pHandles: **void, dwMilliseconds: u32, dwWakeMask: u32, dwFlags: u32) -> u32 #foreign user32;
GetDoubleClickTime :: () -> u32 #foreign user32;
SetWindowDisplayAffinity :: (hwnd: win.HWND, dwAffinity: u32) -> s32 #foreign user32;
SetProcessDpiAwarenessContext :: (value: win.DPI_AWARENESS_CONTEXT) -> s32 #foreign user32;
GetDpiForSystem :: () -> u32 #foreign user32;
GetDpiForWindow :: (hwnd: win.HWND) -> u32 #foreign user32;
GetWindowPlacement :: (hwnd: win.HWND, wp: *WINDOWPLACEMENT) -> s32 #foreign user32;
SetWindowPlacement :: (hwnd: win.HWND, wp: *WINDOWPLACEMENT) -> s32 #foreign user32;
EnumDisplaySettingsW :: (device: *u16, mode: u32, dm: *DEVMODEW) -> s32 #foreign user32;
PostMessageW :: (hwnd: win.HWND, msg: u32, wp: win.WPARAM, lp: win.LPARAM) -> s32 #foreign user32;
SetTimer :: (hwnd: win.HWND, id: u64, elapse_ms: u32, func: *void) -> u64 #foreign user32;
KillTimer :: (hwnd: win.HWND, id: u64) -> s32 #foreign user32;
TrackMouseEvent :: (tme: *TRACKMOUSEEVENT) -> s32 #foreign user32;
IsClipboardFormatAvailable :: (format: u32) -> s32 #foreign user32;
RegisterClipboardFormatW :: (name: *u16) -> u32 #foreign user32;
SystemParametersInfoW :: (action: u32, param: u32, pv: *void, win_ini: u32) -> s32 #foreign user32;
GlobalSize :: (h: *void) -> u64 #foreign kernel32;
GlobalFree :: (h: *void) -> *void #foreign kernel32;
ShellExecuteW :: (hwnd: win.HWND, op: *u16, file: *u16, params: *u16, dir: *u16, show: s32) -> *void #foreign shell32;
ImmGetContext :: (hwnd: win.HWND) -> *void #foreign imm32;
ImmReleaseContext :: (hwnd: win.HWND, himc: *void) -> s32 #foreign imm32;
ImmGetCompositionStringW :: (himc: *void, index: u32, buf: *void, len: u32) -> s32 #foreign imm32;
ImmSetCompositionWindow :: (himc: *void, form: *COMPOSITIONFORM) -> s32 #foreign imm32;
CoInitializeEx :: (reserved: *void, coinit: u32) -> win.HRESULT #foreign ole32;
CoUninitialize :: () #foreign ole32;
CoTaskMemFree :: (p: *void) #foreign ole32;
SHGetKnownFolderPath :: (id: *win.GUID, flags: u32, token: *void, path: **u16) -> win.HRESULT #foreign shell32;
CoCreateInstance :: (clsid: *win.GUID, outer: *void, ctx: u32, iid: *win.GUID, out: **void) -> win.HRESULT #foreign ole32;
OleInitialize :: (reserved: *void) -> win.HRESULT #foreign ole32;
RegisterDragDrop :: (hwnd: win.HWND, target: *void) -> win.HRESULT #foreign ole32;
RevokeDragDrop :: (hwnd: win.HWND) -> win.HRESULT #foreign ole32;
ReleaseStgMedium :: (medium: *STGMEDIUM) #foreign ole32;
CreateStreamOnHGlobal :: (h: *void, delete_on_release: s32, stream: **void) -> win.HRESULT #foreign ole32;

Shell_NotifyIconW :: (msg: u32, data: *NOTIFYICONDATAW) -> s32 #foreign shell32;
SHAppBarMessage :: (msg: u32, data: *APPBARDATA) -> u64 #foreign shell32;
APPBARDATA :: struct { cbSize: u32; hWnd: win.HWND; uCallbackMessage: u32; uEdge: u32; rc: win.RECT; lParam: s64; }
#assert size_of(APPBARDATA) == 48;
ABM_GETSTATE :: 4;
ABM_GETAUTOHIDEBAREX :: 0xB;
ABS_AUTOHIDE :: 1;
RegisterWindowMessageW :: (name: *u16) -> u32 #foreign user32;
GetSystemMetricsForDpi :: (index: s32, dpi: u32) -> s32 #foreign user32;
LoadImageW :: (inst: win.HINSTANCE, name: *u16, type: u32, cx: s32, cy: s32, flags: u32) -> win.HICON #foreign user32;
DestroyIcon :: (icon: win.HICON) -> s32 #foreign user32;
CreateIconIndirect :: (info: *win.ICONINFO) -> win.HICON #foreign user32;
CreateBitmap :: (w: s32, h: s32, planes: u32, bpp: u32, bits: *void) -> win.HBITMAP #foreign gdi32;
CreatePopupMenu :: () -> win.HMENU #foreign user32;
AppendMenuW :: (menu: win.HMENU, flags: u32, id: u64, text: *u16) -> s32 #foreign user32;
TrackPopupMenu :: (menu: win.HMENU, flags: u32, x: s32, y: s32, reserved: s32, hwnd: win.HWND, rect: *win.RECT) -> s32 #foreign user32;
DestroyMenu :: (menu: win.HMENU) -> s32 #foreign user32;
SetForegroundWindow :: (hwnd: win.HWND) -> s32 #foreign user32;
IsIconic :: (hwnd: win.HWND) -> s32 #foreign user32;
IsZoomed :: (hwnd: win.HWND) -> s32 #foreign user32;
DwmExtendFrameIntoClientArea :: (hwnd: win.HWND, margins: *MARGINS) -> win.HRESULT #foreign dwmapi;

MARGINS :: struct { left, right, top, bottom: s32; }

NOTIFYICONDATAW :: struct {
    cbSize: u32;
    hWnd: win.HWND;
    uID: u32;
    uFlags: u32;
    uCallbackMessage: u32;
    hIcon: win.HICON;
    szTip: [128]u16;
    dwState: u32;
    dwStateMask: u32;
    szInfo: [256]u16;
    uVersion: u32;
    szInfoTitle: [64]u16;
    dwInfoFlags: u32;
    guidItem: win.GUID;
    hBalloonIcon: win.HICON;
}
#assert size_of(NOTIFYICONDATAW) == 976;
NIM_ADD :: 0;
NIM_MODIFY :: 1;
NIM_DELETE :: 2;
NIF_MESSAGE :: 1;
NIF_ICON :: 2;
NIF_TIP :: 4;
NIF_INFO :: 0x10;
NIIF_USER :: 4;
NIIF_NOSOUND :: 0x10;
NIIF_LARGE_ICON :: 0x20;
NIN_BALLOONUSERCLICK :: WM_USER + 5;
SM_CXSMICON :: 49;
SM_CXICON :: 11;
SetWindowsHookExW :: (id: s32, proc: *void, mod: win.HINSTANCE, thread: u32) -> *void #foreign user32;
UnhookWindowsHookEx :: (hook: *void) -> s32 #foreign user32;
CallNextHookEx :: (hook: *void, code: s32, wp: win.WPARAM, lp: win.LPARAM) -> win.LRESULT #foreign user32;
SendMessageW :: (hwnd: win.HWND, msg: u32, wp: win.WPARAM, lp: win.LPARAM) -> win.LRESULT #foreign user32;
WH_CBT :: 5;
HCBT_CREATEWND :: 3;
ICON_SMALL :: 0;
ICON_BIG :: 1;
IMAGE_ICON :: 1;
MF_SEPARATOR :: 0x800;
MF_CHECKED :: 0x8;
TPM_RIGHTBUTTON :: 0x0002;
TPM_NONOTIFY :: 0x0080;
TPM_RETURNCMD :: 0x0100;

WM_USER :: 0x0400;
WM_MOUSELEAVE :: 0x02A3;
QS_ALLINPUT :: 0x04FF;
WM_NCMOUSELEAVE :: 0x02A2;
HTCLIENT :: 1;
HTCAPTION :: 2;
HTMAXBUTTON :: 9;
HTLEFT :: 10;
HTRIGHT :: 11;
HTTOP :: 12;
HTTOPLEFT :: 13;
HTTOPRIGHT :: 14;
HTBOTTOM :: 15;
HTBOTTOMLEFT :: 16;
HTBOTTOMRIGHT :: 17;
TME_LEAVE :: 2;
TME_NONCLIENT :: 0x10;
SPI_GETHIGHCONTRAST :: 0x0042;
SPI_GETCLIENTAREAANIMATION :: 0x1042;
SPI_GETWHEELSCROLLLINES :: 0x0068;
SPI_GETWHEELSCROLLCHARS :: 0x006C;
WM_FC_WAKE :: WM_USER + 1;
WM_FC_TRAY :: WM_USER + 2;
TIMER_ANIM :: 1;

COMPOSITIONFORM :: struct {
    dwStyle: u32;
    ptCurrentPos: win.POINT;
    rcArea: win.RECT;
}

WINDOWPLACEMENT :: struct {
    length: u32;
    flags: u32;
    showCmd: u32;
    ptMinPosition: win.POINT;
    ptMaxPosition: win.POINT;
    rcNormalPosition: win.RECT;
}
WPF_RESTORETOMAXIMIZED :: 0x2;

MINMAXINFO :: struct { ptReserved, ptMaxSize, ptMaxPosition, ptMinTrackSize, ptMaxTrackSize: win.POINT; }

TRACKMOUSEEVENT :: struct {
    cbSize: u32;
    dwFlags: u32;
    hwndTrack: win.HWND;
    dwHoverTime: u32;
}

DEVMODEW :: struct {
    dmDeviceName: [32]u16;
    dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra: u16;
    dmFields: u32;
    position_or_printer: [16]u8;
    dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate: s16;
    dmFormName: [32]u16;
    dmLogPixels: u16;
    dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency: u32;
    icm_media_dither_reserved_panning: [8]u32;
}

w: struct {
    hwnd: win.HWND;
    restore: Window_Placement; // set before init by window_placement_restore
    has_restore: bool;
    class_name: string; // set by instance_claim: names the <state>
    instance: win.HINSTANCE;
    frame_wait: *void; // swap chain frame-latency waitable (set by gfx)
    frame_ready: bool; // os_wait already took this frame's signal from frame_wait
    high_surrogate: u16;
    in_size_move: bool;
    size_frame: bool;
    tracking_mouse: bool;
    tracking_nc: bool;
    over_max_button: bool;
    hit_callback: (p: Vector2) -> Window_Hit;
    last_click_time: float64;
    last_click_pos: Vector2;
    last_click_btn: Mouse_Button;
    click_count: int;
    wake_posted: bool;
    composing: bool;
    drop_registered: bool;
    cf_png: u32;
    tray: bool; // the tray icon is shown, so closing the window hides it
    taskbar_created: u32;
    taskbar: *void; // ITaskbarList3, made on the first set_badge
    small_size: s32;
    big_icon: win.HICON;
    icon_hook: *void;
    small_icon: win.HICON;
    tray_badge_icon: win.HICON; // small_icon with the unread dot, while there are mentions
};

// A zero-terminated UTF-16 copy in temp.
wide :: (str: string) -> *u16 {
    p := utf8_to_wide(str,, temp);
    return p;
}

// count -1: zero-terminated.
utf16_to_utf8 :: (p: *u16, count: int, allocator: Allocator) -> string {
    if count == 0 return "";
    out := wide_to_utf8(p, xx count,, allocator);
    return out;
}

update_size :: () {
    r: win.RECT;
    win.GetClientRect(w.hwnd, *r);
    s.scale = cast(float32) GetDpiForWindow(w.hwnd) / 96;
    if s.scale <= 0 s.scale = 1;
    s.size = .{(r.right - r.left) / s.scale, (r.bottom - r.top) / s.scale};
}

update_refresh :: () {
    dm: DEVMODEW;
    dm.dmSize = size_of(DEVMODEW);
    if EnumDisplaySettingsW(null, win.ENUM_CURRENT_SETTINGS, *dm) && dm.dmDisplayFrequency > 1 s.refresh_hz = xx dm.dmDisplayFrequency;
}

pump :: () {
    m: win.MSG;
    while win.PeekMessageW(*m, null, 0, 0, win.PM_REMOVE) {
        if m.message == win.WM_QUIT {
            s.quit = true;
            push_event(.{kind = .Quit, time = time_now()});
            continue;
        }
        win.TranslateMessage(*m);
        win.DispatchMessageW(*m);
    }
}

icon_hook :: (code: s32, wp: win.WPARAM, lp: win.LPARAM) -> win.LRESULT #c_call {
    if code == HCBT_CREATEWND {
        SendMessageW(cast(win.HWND) wp, win.WM_SETICON, ICON_BIG, cast(win.LPARAM) w.big_icon);
        SendMessageW(cast(win.HWND) wp, win.WM_SETICON, ICON_SMALL, cast(win.LPARAM) w.small_icon);
    }
    return CallNextHookEx(null, code, wp, lp);
}

// ---- Tray icon: closing the window hides it there; a left click shows it again, the right-click menu quits

TRAY_OPEN :: 1;
TRAY_QUIT :: 2;
TRAY_MUTE :: 3;
TRAY_DEAF :: 4;

tray_notify :: (op: u32) -> bool {
    nid := NOTIFYICONDATAW.{cbSize = size_of(NOTIFYICONDATAW), hWnd = w.hwnd, uID = 1, uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP, uCallbackMessage = WM_FC_TRAY};
    nid.hIcon = ifx w.tray_badge_icon then w.tray_badge_icon else w.small_icon;
    tip := wide("Fastcord");
    for 0..nid.szTip.count-2 {
        nid.szTip[it] = tip[it];
        if !tip[it] break;
    }
    return Shell_NotifyIconW(op, *nid) != 0;
}

tray_menu :: () {
    m := CreatePopupMenu();
    AppendMenuW(m, 0, TRAY_OPEN, wide("Open Fastcord"));
    AppendMenuW(m, MF_SEPARATOR, 0, null);
    AppendMenuW(m, xx ifx s.tray_mute then MF_CHECKED else 0, TRAY_MUTE, wide("Mute"));
    AppendMenuW(m, xx ifx s.tray_deaf then MF_CHECKED else 0, TRAY_DEAF, wide("Deafen"));
    AppendMenuW(m, MF_SEPARATOR, 0, null);
    AppendMenuW(m, 0, TRAY_QUIT, wide("Quit Fastcord"));
    p: win.POINT;
    win.GetCursorPos(*p);
    // Without the foreground window and the WM_NULL after, the menu stays open when clicking elsewhere
    // (Microsoft KB135788).
    SetForegroundWindow(w.hwnd);
    cmd := TrackPopupMenu(m, TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_NONOTIFY, p.x, p.y, 0, w.hwnd, null);
    PostMessageW(w.hwnd, win.WM_NULL, 0, 0);
    DestroyMenu(m);
    if cmd == TRAY_OPEN window_show();
    if cmd == TRAY_MUTE push_event(.{kind = .Tray_Mute, time = time_now()});
    if cmd == TRAY_DEAF push_event(.{kind = .Tray_Deafen, time = time_now()});
    if cmd == TRAY_QUIT {
        s.quit = true;
        push_event(.{kind = .Quit, time = time_now()});
    }
}

// base with a red dot in its bottom-right corner, as the official tray icon shows unread mentions; with no
// base, the dot alone filling the icon (the taskbar overlay).
badge_icon :: (base: win.HICON) -> win.HICON {
    n := w.small_size;
    px := NewArray(n * n, u32,, temp);
    if base {
        ii: win.ICONINFO;
        if win.GetIconInfo(base, *ii) == .FALSE return null;
        defer { win.DeleteObject(ii.hbmColor); win.DeleteObject(ii.hbmMask); }
        bmi: win.BITMAPINFO;
        bmi.bmiHeader = .{biSize = size_of(win.BITMAPINFOHEADER), biWidth = n, biHeight = -n, biPlanes = 1, biBitCount = 32};
        dc := win.GetDC(null);
        got := win.GetDIBits(dc, ii.hbmColor, 0, xx n, px.data, *bmi, win.DIB_RGB_COLORS);
        win.ReleaseDC(null, dc);
        if got != n return null;
    }
    // Straight (not premultiplied) BGRA, so blend the dot over each pixel with its alpha.
    ch :: (v: u32, shift: u32, dot: float, a: float, cov: float, oa: float) -> u32 {
        return (cast(u32) ((dot * cov + cast(float) ((v >> shift) & 0xff) * a * (1 - cov)) / oa + 0.5)) << shift;
    }
    r := cast(float) n * ifx base then 0.24 else 0.5;
    c := cast(float) n - r;
    for y: 0..n-1 for x: 0..n-1 {
        dx, dy := cast(float) x + 0.5 - c, cast(float) y + 0.5 - c;
        cov := clamp(r - sqrt(dx * dx + dy * dy) + 0.5, 0, 1);
        if cov <= 0 continue;
        p := *px[y * n + x];
        a := cast(float) (<<p >> 24) / 255;
        oa := cov + a * (1 - cov);
        <<p = ((cast(u32) (oa * 255 + 0.5)) << 24) | ch(<<p, 16, 0xf2, a, cov, oa) | ch(<<p, 8, 0x3f, a, cov, oa) | ch(<<p, 0, 0x43, a, cov, oa);
    }
    mask := NewArray((n + 15) / 16 * 2 * n, u8,, temp);
    out := win.ICONINFO.{fIcon = .TRUE, hbmColor = CreateBitmap(n, n, 1, 32, px.data), hbmMask = CreateBitmap(n, n, 1, 1, mask.data)};
    defer { win.DeleteObject(out.hbmColor); win.DeleteObject(out.hbmMask); }
    return CreateIconIndirect(*out);
}

// ---- Clipboard: images and files

cf_png :: () -> u32 {
    if !w.cf_png w.cf_png = RegisterClipboardFormatW(wide("PNG"));
    return w.cf_png;
}

// Opens the clipboard from a worker thread: retried briefly, another process may hold it. Writing needs the
// window as owner (with none, SetClipboardData fails after EmptyClipboard).
open_clipboard_any :: (owner: win.HWND = null) -> bool {
    for 1..10 {
        if win.OpenClipboard(owner) != .FALSE return true;
        win.Sleep(10);
    }
    return false;
}

global_bytes :: (h: *void, allocator: Allocator) -> []u8 {
    if !h return .[];
    p := cast(*u8) win.GlobalLock(h);
    if !p return .[];
    defer win.GlobalUnlock(h);
    out := NewArray(cast(int) GlobalSize(h), u8, false,, allocator);
    memcpy(out.data, p, out.count);
    return out;
}

CLSID_WICImagingFactory := win.GUID.{0xCACAF262, 0x9370, 0x4615, .[0xA1, 0x3B, 0x9F, 0x55, 0x39, 0xDA, 0x4C, 0x0A]};
IID_IWICImagingFactory := win.GUID.{0xEC5EC8A9, 0xC395, 0x4314, .[0x9C, 0x77, 0x54, 0xD7, 0xA9, 0x35, 0xFF, 0x70]};
GUID_ContainerFormatPng := win.GUID.{0x1B7CFAF4, 0x713F, 0x473C, .[0xBB, 0xCD, 0x61, 0x37, 0x42, 0x5F, 0xAE, 0xAF]};
GUID_WICPixelFormat32bppBGRA :: win.GUID.{0x6FDDC324, 0x4E03, 0x4BFE, .[0xB1, 0x85, 0x3D, 0x77, 0x76, 0x8D, 0xC9, 0x0F]};

// COM method `idx` of obj's vtable, as procedure type T.
vt :: inline (obj: *void, idx: int, $T: Type) -> T #no_context { return cast(T) (cast(***void) obj).*[idx]; }

release :: (obj: *void) #no_context {
    if obj vt(obj, 2, #type (*void) -> u32 #c_call)(obj);
}

// RGBA8 pixels (swapped to BGRA in place) as PNG, by WIC's PNG encoder (the OS's, as NSBitmapImageRep is on
// macOS). Empty on failure. Worker thread.
wic_png :: (px: []u8, width: int, height: int, allocator: Allocator) -> []u8 {
    for i: 0..px.count/4-1 px[i*4], px[i*4 + 2] = px[i*4 + 2], px[i*4];
    com := CoInitializeEx(null, 0 /*COINIT_MULTITHREADED*/) >= 0;
    defer if com CoUninitialize();
    factory, enc, frame, stream: *void;
    defer {
        release(frame);
        release(enc);
        release(stream);
        release(factory);
    }
    format := GUID_WICPixelFormat32bppBGRA;
    // IWICImagingFactory::CreateEncoder; IWICBitmapEncoder::Initialize (WICBitmapEncoderNoCache),
    // CreateNewFrame, Commit; IWICBitmapFrameEncode::Initialize, SetSize, SetPixelFormat, WritePixels, Commit
    HR :: win.HRESULT;
    ok := CoCreateInstance(*CLSID_WICImagingFactory, null, 1 /*CLSCTX_INPROC_SERVER*/, *IID_IWICImagingFactory, *factory) >= 0 &&
        vt(factory, 8, #type (*void, *win.GUID, *win.GUID, **void) -> HR #c_call)(factory, *GUID_ContainerFormatPng, null, *enc) >= 0 &&
        CreateStreamOnHGlobal(null, 1, *stream) >= 0 &&
        vt(enc, 3, #type (*void, *void, u32) -> HR #c_call)(enc, stream, 2) >= 0 &&
        vt(enc, 10, #type (*void, **void, *void) -> HR #c_call)(enc, *frame, null) >= 0 &&
        vt(frame, 3, #type (*void, *void) -> HR #c_call)(frame, null) >= 0 &&
        vt(frame, 4, #type (*void, u32, u32) -> HR #c_call)(frame, xx width, xx height) >= 0 &&
        vt(frame, 6, #type (*void, *win.GUID) -> HR #c_call)(frame, *format) >= 0 &&
        format == GUID_WICPixelFormat32bppBGRA &&
        vt(frame, 10, #type (*void, u32, u32, u32, *u8) -> HR #c_call)(frame, xx height, xx (width * 4), xx px.count, px.data) >= 0 &&
        vt(frame, 12, #type (*void) -> HR #c_call)(frame) >= 0 &&
        vt(enc, 11, #type (*void) -> HR #c_call)(enc) >= 0;
    if !ok return .[];
    // IStream::Seek (5) to the end for the size and back to the start, IStream::Read (3)
    seek :: #type (*void, s64, u32, *u64) -> HR #c_call;
    size: u64;
    if vt(stream, 5, seek)(stream, 0, 2 /*END*/, *size) < 0 || vt(stream, 5, seek)(stream, 0, 0 /*SET*/, null) < 0 return .[];
    out := NewArray(cast(int) size, u8, false,, allocator);
    got: u32;
    if vt(stream, 3, #type (*void, *void, u32, *u32) -> HR #c_call)(stream, out.data, xx size, *got) < 0 || got != out.count {
        array_free(out,, allocator);
        return .[];
    }
    return out;
}

operator == :: (a: win.GUID, b: win.GUID) -> bool { return memcmp(*a, *b, size_of(win.GUID)) == 0; }

hdrop_paths :: (hdrop: *void, allocator: Allocator) -> []string {
    out: [..]string;
    out.allocator = allocator;
    for i: 0..cast(s64) win.DragQueryFileW(hdrop, 0xFFFF_FFFF, null, 0) - 1 {
        l := win.DragQueryFileW(hdrop, xx i, null, 0);
        buf := NewArray(l + 1, u16,, temp);
        win.DragQueryFileW(hdrop, xx i, buf.data, l + 1);
        array_add(*out, utf16_to_utf8(buf.data, l, allocator));
    }
    return out;
}

// ---- Drag and drop: a static IDropTarget

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

IDataObject :: struct {
    vtbl: *struct {
        QueryInterface, AddRef, Release: *void;
        GetData: (this: *IDataObject, fmt: *FORMATETC, medium: *STGMEDIUM) -> win.HRESULT #c_call;
        // the rest is not called
    };
}

POINTL :: struct { x, y: s32; }

IDropTarget_Vtbl :: struct {
    QueryInterface: (this: *void, riid: *win.GUID, out: **void) -> win.HRESULT #c_call;
    AddRef: (this: *void) -> u32 #c_call;
    Release: (this: *void) -> u32 #c_call;
    DragEnter: (this: *void, data: *IDataObject, keys: u32, pt: POINTL, effect: *u32) -> win.HRESULT #c_call;
    DragOver: (this: *void, keys: u32, pt: POINTL, effect: *u32) -> win.HRESULT #c_call;
    DragLeave: (this: *void) -> win.HRESULT #c_call;
    Drop: (this: *void, data: *IDataObject, keys: u32, pt: POINTL, effect: *u32) -> win.HRESULT #c_call;
}

DROPEFFECT_COPY :: 1;

drop_vtbl := IDropTarget_Vtbl.{
    QueryInterface = (this: *void, riid: *win.GUID, out: **void) -> win.HRESULT #c_call {
        // IUnknown {00000000-0000-0000-C000-000000000046} / IDropTarget {00000122-0000-0000-C000-000000000046}
        if riid && (riid.Data1 == 0 || riid.Data1 == 0x122) && riid.Data2 == 0 && riid.Data3 == 0 && riid.Data4[0] == 0xC0 && riid.Data4[7] == 0x46 {
            out.* = this;
            return 0;
        }
        out.* = null;
        return cast,no_check(win.HRESULT) 0x8000_4002; // E_NOINTERFACE
    },
    AddRef = (this: *void) -> u32 #c_call { return 1; }, // static object
    Release = (this: *void) -> u32 #c_call { return 1; },
    DragEnter = (this: *void, data: *IDataObject, keys: u32, pt: POINTL, effect: *u32) -> win.HRESULT #c_call {
        c := s.ctx; push_context,defer_pop c;
        p := win.POINT.{pt.x, pt.y};
        win.ScreenToClient(w.hwnd, *p);
        push_event(.{kind = .Drag_Enter, pos = .{p.x / s.scale, p.y / s.scale}, time = time_now()});
        if effect effect.* = DROPEFFECT_COPY;
        return 0;
    },
    DragOver = (this: *void, keys: u32, pt: POINTL, effect: *u32) -> win.HRESULT #c_call {
        if effect effect.* = DROPEFFECT_COPY;
        return 0;
    },
    DragLeave = (this: *void) -> win.HRESULT #c_call {
        c := s.ctx; push_context,defer_pop c;
        push_event(.{kind = .Drag_Leave, time = time_now()});
        return 0;
    },
    Drop = (this: *void, data: *IDataObject, keys: u32, pt: POINTL, effect: *u32) -> win.HRESULT #c_call {
        c := s.ctx; push_context,defer_pop c;
        if data {
            f := FORMATETC.{cfFormat = win.CF_HDROP, dwAspect = 1, lindex = -1, tymed = 1 /*TYMED_HGLOBAL*/};
            med: STGMEDIUM;
            if data.vtbl.GetData(data, *f, *med) == 0 {
                for hdrop_paths(med.handle, temp) push_event(.{kind = .File_Drop, text = it, time = time_now()});
                ReleaseStgMedium(*med);
            }
        }
        push_event(.{kind = .Drag_Leave, time = time_now()});
        if effect effect.* = DROPEFFECT_COPY;
        return 0;
    },
};

drop_target := *drop_vtbl; // the object: a pointer to its vtable

drop_target_register :: (hwnd: win.HWND) -> bool {
    if OleInitialize(null) < 0 || RegisterDragDrop(hwnd, *drop_target) < 0 return false;
    w.drop_registered = true;
    return true;
}

// ---------------------------------------------------------------------------
// Input

current_mods :: () -> Mod {
    m: Mod;
    if win.GetKeyState(win.VK_SHIFT) < 0 m |= .Shift;
    if win.GetKeyState(win.VK_CONTROL) < 0 m |= .Ctrl;
    if win.GetKeyState(win.VK_MENU) < 0 m |= .Alt;
    if win.GetKeyState(win.VK_LWIN) < 0 || win.GetKeyState(win.VK_RWIN) < 0 m |= .Cmd;
    return m;
}

map_vk :: (vk: win.WPARAM, lp: win.LPARAM) -> Key {
    if vk >= #char "A" && vk <= #char "Z" return cast(Key) (cast(int) Key.A + cast(int) (vk - #char "A"));
    if vk >= #char "0" && vk <= #char "9" return cast(Key) (cast(int) Key.N0 + cast(int) (vk - #char "0"));
    if vk >= win.VK_F1 && vk <= win.VK_F12 return cast(Key) (cast(int) Key.F1 + cast(int) (vk - win.VK_F1));
    if vk == {
        case win.VK_SPACE;  return .Space;
        case win.VK_RETURN; return ifx (lp >> 24) & 1 then .Keypad_Enter else .Enter;
        case win.VK_TAB;    return .Tab;
        case win.VK_BACK;   return .Backspace;
        case win.VK_DELETE; return .Delete;
        case win.VK_ESCAPE; return .Escape;
        case win.VK_LEFT;   return .Left;
        case win.VK_RIGHT;  return .Right;
        case win.VK_UP;     return .Up;
        case win.VK_DOWN;   return .Down;
        case win.VK_HOME;   return .Home;
        case win.VK_END;    return .End;
        case win.VK_PRIOR;  return .Page_Up;
        case win.VK_NEXT;   return .Page_Down;
        case win.VK_SHIFT;   #through; case win.VK_LSHIFT;   #through; case win.VK_RSHIFT;   return .Shift;
        case win.VK_CONTROL; #through; case win.VK_LCONTROL; #through; case win.VK_RCONTROL; return .Ctrl;
        case win.VK_MENU;    #through; case win.VK_LMENU;    #through; case win.VK_RMENU;    return .Alt;
        case win.VK_LWIN;    #through; case win.VK_RWIN;     return .Cmd;
        case win.VK_CAPITAL;    return .Caps_Lock;
        case win.VK_OEM_MINUS;  return .Minus;
        case win.VK_OEM_PLUS;   return .Equals;
        case win.VK_OEM_4;      return .Left_Bracket;
        case win.VK_OEM_6;      return .Right_Bracket;
        case win.VK_OEM_5;      return .Backslash;
        case win.VK_OEM_1;      return .Semicolon;
        case win.VK_OEM_7;      return .Apostrophe;
        case win.VK_OEM_COMMA;  return .Comma;
        case win.VK_OEM_PERIOD; return .Period;
        case win.VK_OEM_2;      return .Slash;
        case win.VK_OEM_3;      return .Grave;
    }
    return .None;
}

// GET_X_LPARAM / GET_Y_LPARAM: signed 16-bit halves.
lparam_x :: (lp: win.LPARAM) -> s32 { return cast(s16) (lp & 0xffff); }
lparam_y :: (lp: win.LPARAM) -> s32 { return cast(s16) ((lp >> 16) & 0xffff); }

lparam_pos :: (lp: win.LPARAM) -> Vector2 { return .{lparam_x(lp) / s.scale, lparam_y(lp) / s.scale}; }

// A non-client message's screen point as a client message's lParam.
screen_to_client :: (hwnd: win.HWND, lp: win.LPARAM) -> win.LPARAM {
    pt := win.POINT.{lparam_x(lp), lparam_y(lp)};
    win.ScreenToClient(hwnd, *pt);
    return cast(win.LPARAM) (((cast(s64) pt.y & 0xffff) << 16) | (cast(s64) pt.x & 0xffff));
}

mouse_button_event :: (kind: Event_Kind, btn: Mouse_Button, lp: win.LPARAM) {
    pos := lparam_pos(lp);
    now := time_now();
    if kind == .Mouse_Down {
        d := pos - w.last_click_pos;
        dbl := GetDoubleClickTime() / 1000.0;
        if btn == w.last_click_btn && now - w.last_click_time <= dbl && d.x * d.x + d.y * d.y < 16 w.click_count += 1;
        else w.click_count = 1;
        w.last_click_time = now;
        w.last_click_pos = pos;
        w.last_click_btn = btn;
        win.SetCapture(w.hwnd);
    } else {
        win.ReleaseCapture();
    }
    push_event(.{kind = kind, button = btn, pos = pos, mods = current_mods(), click_count = w.click_count, time = now});
}

update_ime_window :: () {
    himc := ImmGetContext(w.hwnd);
    if !himc return;
    defer ImmReleaseContext(w.hwnd, himc);
    cf := COMPOSITIONFORM.{dwStyle = 0x0002 /*CFS_POINT*/, ptCurrentPos = .{xx (s.ime_rect.x * s.scale), xx ((s.ime_rect.y + s.ime_rect.w) * s.scale)}};
    ImmSetCompositionWindow(himc, *cf);
}

wndproc :: (hwnd: win.HWND, msg: u32, wp: win.WPARAM, lp: win.LPARAM) -> win.LRESULT #c_call {
    c := s.ctx; push_context,defer_pop c;
    if w.taskbar_created && msg == w.taskbar_created {
        w.tray = tray_notify(NIM_ADD); // Explorer restarted and lost every tray icon.
        return 0;
    }
    if msg == {
        case WM_FC_WAKE;
            atomic_store(*w.wake_posted, false);
            return 0;
        case WM_COPYDATA;
            cds := cast(*COPYDATASTRUCT) lp;
            if cds.dwData != COPYDATA_OPEN || cds.cbData > INSTANCE_MESSAGE_MAX return 0;
            push_event(.{kind = .Open_Url, text = .{cds.cbData, cds.lpData}, time = time_now()});
            request_frame();
            return 1;
        case WM_FC_TRAY;
            ev := lp & 0xffff;
            if ev == win.WM_LBUTTONUP || ev == NIN_BALLOONUSERCLICK window_show();
            else if ev == win.WM_RBUTTONUP tray_menu();
            return 0;
        case win.WM_QUERYENDSESSION;
            return 1;
        case win.WM_ENDSESSION;
            // The session ends (log off, restart, shutdown): the process is killed once this returns.
            if wp && s.exit_callback {
                s.quit = true;
                s.exit_callback();
            }
            return 0;
        case win.WM_CLOSE;
            if w.tray {
                win.ShowWindow(hwnd, win.SW_HIDE);
                return 0;
            }
            s.quit = true;
            push_event(.{kind = .Quit, time = time_now()});
            return 0;
        case win.WM_SIZE;
            update_size();
            push_event(.{kind = .Resize, pos = s.size, time = time_now()});
            if w.in_size_move {
                w.size_frame = true;
                run_frame_callback();
                w.size_frame = false;
            }
            return 0;
        case win.WM_GETMINMAXINFO;
            mm := cast(*MINMAXINFO) lp;
            dpi := GetDpiForWindow(hwnd);
            sc := cast(float32) dpi / 96;
            mm.ptMinTrackSize = .{xx (MIN_WINDOW_W * sc), xx (MIN_WINDOW_H * sc)};
            return 0;
        case win.WM_NCCALCSIZE;
            // A maximized window hangs over the monitor by its resize frame; keep the content on screen.
            if wp && IsZoomed(hwnd) {
                r := cast(*win.RECT) lp; // NCCALCSIZE_PARAMS.rgrc[0]
                dpi := GetDpiForWindow(hwnd);
                pad := GetSystemMetricsForDpi(win.SM_CXPADDEDBORDER, dpi);
                fx := GetSystemMetricsForDpi(win.SM_CXFRAME, dpi) + pad;
                fy := GetSystemMetricsForDpi(win.SM_CYFRAME, dpi) + pad;
                r.left += fx;
                r.right -= fx;
                r.top += fy;
                r.bottom -= fy;
                // An auto-hiding taskbar slides up only when the mouse reaches a pixel no window covers:
                // leave 2 px free on its edge of this monitor, as Chromium does.
                abd := APPBARDATA.{cbSize = size_of(APPBARDATA)};
                mi := win.MONITORINFO.{cbSize = size_of(win.MONITORINFO)};
                if (SHAppBarMessage(ABM_GETSTATE, *abd) & ABS_AUTOHIDE) && win.GetMonitorInfoW(win.MonitorFromWindow(hwnd, win.MONITOR_DEFAULTTONEAREST), *mi) {
                    for edge: 0..3 { // ABE_LEFT, TOP, RIGHT, BOTTOM
                        abd.uEdge = xx edge;
                        abd.rc = mi.rcMonitor;
                        if !SHAppBarMessage(ABM_GETAUTOHIDEBAREX, *abd) continue;
                        if edge == {
                            case 0; r.left += 2;
                            case 1; r.top += 2;
                            case 2; r.right -= 2;
                            case 3; r.bottom -= 2;
                        }
                    }
                }
            }
            return 0;
        case win.WM_NCHITTEST;
            pt := win.POINT.{lparam_x(lp), lparam_y(lp)};
            win.ScreenToClient(hwnd, *pt);
            if !IsZoomed(hwnd) {
                r: win.RECT;
                win.GetClientRect(hwnd, *r);
                // Edges 8pt deep, rounded up to whole pixels; corners reach 16pt along each edge.
                e := cast(s32) (8 * s.scale + 0.99);
                c := cast(s32) (16 * s.scale);
                l, t, rt, b := pt.x < e, pt.y < e, pt.x >= r.right - e, pt.y >= r.bottom - e;
                if l || t || rt || b {
                    cl, ct, cr, cb := pt.x < c, pt.y < c, pt.x >= r.right - c, pt.y >= r.bottom - c;
                    if (t && cl) || (l && ct) return HTTOPLEFT;
                    if (t && cr) || (rt && ct) return HTTOPRIGHT;
                    if (b && cl) || (l && cb) return HTBOTTOMLEFT;
                    if (b && cr) || (rt && cb) return HTBOTTOMRIGHT;
                    if t return HTTOP;
                    if b return HTBOTTOM;
                    return ifx l then HTLEFT else HTRIGHT;
                }
            }
            if w.hit_callback {
                hit := w.hit_callback(.{pt.x / dpi_scale(), pt.y / dpi_scale()});
                if hit == .Caption return HTCAPTION;
                if hit == .Maximize return HTMAXBUTTON;
            }
            return HTCLIENT;
        // Over HTMAXBUTTON the mouse sends non-client messages; hand them to the app's button as content
        // input, and keep the press from DefWindowProc, which would track a system button of its own.
        case win.WM_NCMOUSEMOVE;
            if wp == HTMAXBUTTON {
                if !w.tracking_nc {
                    tme := TRACKMOUSEEVENT.{cbSize = size_of(TRACKMOUSEEVENT), dwFlags = TME_LEAVE | TME_NONCLIENT, hwndTrack = hwnd};
                    TrackMouseEvent(*tme);
                    w.tracking_nc = true;
                }
                w.over_max_button = true;
                push_event(.{kind = .Mouse_Move, pos = lparam_pos(screen_to_client(hwnd, lp)), mods = current_mods(), time = time_now()});
            } else if w.over_max_button {
                w.over_max_button = false;
                push_event(.{kind = .Mouse_Leave, time = time_now()});
            }
        case WM_NCMOUSELEAVE;
            w.tracking_nc = false;
            if w.over_max_button {
                w.over_max_button = false;
                push_event(.{kind = .Mouse_Leave, time = time_now()});
            }
        case win.WM_NCLBUTTONDOWN; #through;
        case win.WM_NCLBUTTONUP;
            if wp == HTMAXBUTTON {
                mouse_button_event(ifx msg == win.WM_NCLBUTTONDOWN then .Mouse_Down else .Mouse_Up, .Left, screen_to_client(hwnd, lp));
                return 0;
            }
        case win.WM_DPICHANGED;
            r := cast(*win.RECT) lp;
            win.SetWindowPos(hwnd, null, r.left, r.top, r.right - r.left, r.bottom - r.top, win.SWP_NOZORDER | win.SWP_NOACTIVATE);
            update_size();
            push_event(.{kind = .Resize, pos = s.size, time = time_now()});
            return 0;
        case win.WM_ENTERSIZEMOVE;
            w.in_size_move = true;
            SetTimer(hwnd, TIMER_ANIM, 1, null);
            return 0;
        case win.WM_EXITSIZEMOVE;
            w.in_size_move = false;
            KillTimer(hwnd, TIMER_ANIM);
            return 0;
        case win.WM_TIMER;
            if wp == TIMER_ANIM && w.in_size_move && atomic_load(*s.frame_requested) run_frame_callback();
            return 0;
        case win.WM_SETFOCUS;
            push_event(.{kind = .Focus_Gained, time = time_now()});
            return 0;
        case win.WM_KILLFOCUS;
            push_event(.{kind = .Focus_Lost, time = time_now()});
            return 0;
        case win.WM_SETCURSOR;
            if (lp & 0xffff) == HTCLIENT {
                os_apply_cursor();
                return 1;
            }
        case win.WM_KEYDOWN; #through;
        case win.WM_SYSKEYDOWN;
            push_event(.{kind = .Key_Down, key = map_vk(wp, lp), mods = current_mods(), is_repeat = ((lp >> 30) & 1) != 0, time = time_now()});
            if !(msg == win.WM_SYSKEYDOWN && wp == win.VK_F4) return 0; // let Alt+F4 through
        case win.WM_KEYUP; #through;
        case win.WM_SYSKEYUP;
            push_event(.{kind = .Key_Up, key = map_vk(wp, lp), mods = current_mods(), time = time_now()});
            return 0;
        case win.WM_CHAR;
            u := cast(u16) wp;
            if u >= 0xD800 && u <= 0xDBFF {
                w.high_surrogate = u;
                return 0;
            }
            ch: u32 = u;
            if u >= 0xDC00 && u <= 0xDFFF && w.high_surrogate ch = 0x10000 + ((cast(u32) w.high_surrogate - 0xD800) << 10) + (u - 0xDC00);
            w.high_surrogate = 0;
            if ch < 0x20 || ch == 0x7f return 0;
            mods := current_mods();
            if (mods & .Ctrl) && !(mods & .Alt) return 0; // ctrl shortcuts are Key_Down only (AltGr = ctrl+alt types text)
            buf: [4]u8;
            text := string.{0, buf.data};
            character_utf32_to_utf8(ch, *text);
            push_event(.{kind = .Text, text = text, time = time_now()});
            return 0;
        case win.WM_IME_STARTCOMPOSITION;
            update_ime_window();
            w.composing = true;
        case win.WM_IME_COMPOSITION;
            update_ime_window();
            if lp & 0x0008 /*GCS_COMPSTR*/ {
                himc := ImmGetContext(hwnd);
                if himc {
                    bytes := ImmGetCompositionStringW(himc, 0x0008, null, 0);
                    text := "";
                    if bytes > 0 {
                        wbuf := NewArray(bytes / 2, u16,, temp);
                        ImmGetCompositionStringW(himc, 0x0008, wbuf.data, xx bytes);
                        text = utf16_to_utf8(wbuf.data, wbuf.count, temp);
                    }
                    cursor := ImmGetCompositionStringW(himc, 0x0080 /*GCS_CURSORPOS*/, null, 0);
                    ImmReleaseContext(hwnd, himc);
                    cb := utf16_to_byte(text, cursor);
                    push_event(.{kind = .Composition, text = text, composition_sel = .[cb, cb], time = time_now()});
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
                tme := TRACKMOUSEEVENT.{cbSize = size_of(TRACKMOUSEEVENT), dwFlags = TME_LEAVE, hwndTrack = hwnd};
                TrackMouseEvent(*tme);
                w.tracking_mouse = true;
            }
            push_event(.{kind = .Mouse_Move, pos = lparam_pos(lp), mods = current_mods(), time = time_now()});
            return 0;
        case WM_MOUSELEAVE;
            w.tracking_mouse = false;
            push_event(.{kind = .Mouse_Leave, time = time_now()});
            return 0;
        case win.WM_LBUTTONDOWN; mouse_button_event(.Mouse_Down, .Left, lp); return 0;
        case win.WM_LBUTTONUP;   mouse_button_event(.Mouse_Up, .Left, lp); return 0;
        case win.WM_RBUTTONDOWN; mouse_button_event(.Mouse_Down, .Right, lp); return 0;
        case win.WM_RBUTTONUP;   mouse_button_event(.Mouse_Up, .Right, lp); return 0;
        case win.WM_MBUTTONDOWN; mouse_button_event(.Mouse_Down, .Middle, lp); return 0;
        case win.WM_MBUTTONUP;   mouse_button_event(.Mouse_Up, .Middle, lp); return 0;
        case win.WM_XBUTTONDOWN; mouse_button_event(.Mouse_Down, ifx ((wp >> 16) & 0xffff) == 1 then .X1 else .X2, lp); return 1;
        case win.WM_XBUTTONUP;   mouse_button_event(.Mouse_Up, ifx ((wp >> 16) & 0xffff) == 1 then .X1 else .X2, lp); return 1;
        case win.WM_MOUSEWHEEL; #through;
        case win.WM_MOUSEHWHEEL;
            // Chromium on Windows: the system's lines (or chars) per notch at 100/3 px each; "one screen
            // at a time" (0xffffffff) steps 87.5% of the view, Blink's page step.
            lines: u32 = 3;
            SystemParametersInfoW(xx ifx msg == win.WM_MOUSEWHEEL then SPI_GETWHEELSCROLLLINES else SPI_GETWHEELSCROLLCHARS, 0, *lines, 0);
            step := cast(float32) lines * 100 / 3;
            if lines == 0xffff_ffff {
                r: win.RECT;
                win.GetClientRect(hwnd, *r);
                step = (ifx msg == win.WM_MOUSEWHEEL then r.bottom - r.top else r.right - r.left) / s.scale * 0.875;
            }
            delta := cast(s16) ((wp >> 16) & 0xffff) / 120.0 * step;
            pt := win.POINT.{lparam_x(lp), lparam_y(lp)};
            win.ScreenToClient(hwnd, *pt);
            e := Event.{kind = .Scroll, pos = .{pt.x / s.scale, pt.y / s.scale}, mods = current_mods(), time = time_now()};
            if msg == win.WM_MOUSEWHEEL e.delta.y = delta; else e.delta.x = -delta;
            push_event(e);
            return 0;
        case win.WM_DROPFILES;
            hdrop := cast(*void) wp;
            for hdrop_paths(hdrop, temp) push_event(.{kind = .File_Drop, text = it, time = time_now()});
            win.DragFinish(hdrop);
            return 0;
    }
    return win.DefWindowProcW(hwnd, msg, wp, lp);
}
