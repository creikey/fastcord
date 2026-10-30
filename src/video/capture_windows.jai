// Camera capture (Media Foundation source reader), screen capture (DXGI desktop duplication) and window
// capture (Windows.Graphics.Capture), scaled and converted to NV12 by the D3D11 video processor, and
// soundshare (WASAPI process loopback). Each capture runs on its own thread, which opens the device too, so
// starting one never blocks the caller. Frames are yuv.Nv12.

// Enumerating devices can take a while, so this only knows what the last camera_start found: until then,
// assume there is one.
camera_supported :: () -> bool { return atomic_load(*camera_count) != 0; }

camera_start :: (on_frame: Frame_Proc, user: *void, width := 1280, height := 720, fps := 30, device_id := "") -> *Capture {
	c := New(Capture);
	c.* = .{on_frame = on_frame, user = user, width = width, height = height, fps = fps, camera = true, device = copy_string(device_id)};
	start(c, camera_thread);
	return c;
}

screen_supported :: () -> bool { return true; }

// Screens (DXGI outputs) and top-level windows, listed synchronously: both enumerations are fast and touch
// neither disk nor network. Screens' thumbnails are taken here (GDI, a few milliseconds each), windows' on
// a thread, since PrintWindow waits for the window's app to paint.
screen_targets_refresh :: () {
	for screens free(it.name);
	screens.count = 0;
	factory: *IDXGIFactory1;
	if SUCCEEDED(CreateDXGIFactory1(uid(IDXGIFactory1_UUID), cast(**void) *factory)) {
		defer IUnknown_Release(factory);
		a: u32;
		adapter: *IDXGIAdapter1;
		while SUCCEEDED(IDXGIFactory1_EnumAdapters1(factory, a, *adapter)) {
			o: u32;
			output: *IDXGIOutput;
			while SUCCEEDED(IDXGIAdapter_EnumOutputs(adapter, o, *output)) {
				desc: DXGI_OUTPUT_DESC;
				IDXGIOutput_GetDesc(output, *desc);
				IUnknown_Release(output);
				r := desc.DesktopCoordinates;
				if desc.AttachedToDesktop array_add(*screens, .{id = (a << 8) | o, name = sprint("Screen %", screens.count + 1), width = r.right - r.left, height = r.bottom - r.top, x = r.left, y = r.top});
				o += 1;
			}
			IUnknown_Release(adapter);
			a += 1;
		}
	}
	thumbs_clear();
	screen := GetDC(null);
	defer ReleaseDC(null, screen);
	for screens {
		px, w, h := thumb_from(screen, it.x, it.y, it.width, it.height);
		if px thumb_add(false, it.id, px, w, h);
	}

	// Windows, front to back, as the taskbar would show them: visible, unowned, not tool windows, not
	// cloaked (other virtual desktops, suspended apps), titled, not fastcord's own.
	me := GetCurrentProcessId();
	shell := GetShellWindow();
	h := GetTopWindow(null);
	for 1..4096 {
		if !h break;
		defer h = GetWindow(h, GW_HWNDNEXT);
		if h == shell || !IsWindowVisible(h) || IsIconic(h) || GetWindow(h, GW_OWNER) continue;
		if GetWindowLongW(h, GWL_EXSTYLE) & WS_EX_TOOLWINDOW continue;
		cloaked: u32;
		DwmGetWindowAttribute(h, DWMWA_CLOAKED, *cloaked, size_of(u32));
		if cloaked continue;
		pid: u32;
		GetWindowThreadProcessId(h, *pid);
		if pid == me continue;
		title: [256]u16;
		n := GetWindowTextW(h, title.data, title.count);
		if n <= 0 continue;
		r: RECT;
		if DwmGetWindowAttribute(h, DWMWA_EXTENDED_FRAME_BOUNDS, *r, size_of(RECT)) < 0 GetWindowRect(h, *r);
		if r.right - r.left < 32 || r.bottom - r.top < 32 continue;
		array_add(*screens, .{is_window = true, id = cast(u32) cast(u64) h, name = wide_to_utf8(title.data, n), width = r.right - r.left, height = r.bottom - r.top, x = r.left, y = r.top});
	}
	if wthumbs.started {
		if !thread_is_done(*wthumbs.thread) return; // the last refresh's thumbnails are still being taken
		thread_deinit(*wthumbs.thread);
	}
	wthumbs.windows.count = 0;
	for screens if it.is_window array_add(*wthumbs.windows, .{is_window = true, id = it.id});
	{ locks.guard(*thumbs.mu); wthumbs.gen = thumbs.gen; }
	wthumbs.started = true;
	thread_init(*wthumbs.thread, (t: *Thread) -> s64 {
		screen := GetDC(null);
		defer ReleaseDC(null, screen);
		for wthumbs.windows {
			hwnd := target_hwnd(it);
			r: RECT;
			if !IsWindow(hwnd) || IsHungAppWindow(hwnd) || !GetWindowRect(hwnd, *r) continue;
			w, h := r.right - r.left, r.bottom - r.top;
			mem := CreateCompatibleDC(screen);
			bmp := CreateCompatibleBitmap(screen, xx w, xx h);
			old := SelectObject(mem, bmp);
			px: []u8;
			tw, th: int;
			if PrintWindow(hwnd, mem, PW_RENDERFULLCONTENT) != .FALSE px, tw, th = thumb_from(mem, 0, 0, w, h);
			SelectObject(mem, old);
			DeleteObject(bmp);
			DeleteDC(mem);
			if !px continue;
			locks.guard(*thumbs.mu);
			if thumbs.gen != wthumbs.gen { array_free(px); break; } // a newer refresh cleared the list
			array_add(*thumbs.list, .{true, it.id, px, tw, th});
		}
		return 0;
	});
	thread_start(*wthumbs.thread);
}

screen_targets :: () -> []Screen_Target, ready: bool { return screens, true; }

// A screen through DXGI desktop duplication, with the cursor drawn in; a window through
// Windows.Graphics.Capture (Windows 10 1903+), which draws the cursor itself. on_audio: the sound as well
// (audio_thread).
screen_start :: (target: Screen_Target, on_frame: Frame_Proc, user: *void, fps := 30, max_height := 1080, on_audio: Audio_Proc = null) -> *Capture {
	c := New(Capture);
	w, h := max(target.width, 2), max(target.height, 2);
	if h > max_height { w = w * max_height / h; h = max_height; }
	c.* = .{on_frame = on_frame, user = user, width = w & ~1, height = h & ~1, fps = max(fps, 1), target = target};
	c.target.name = "";
	start(c, ifx target.is_window then window_thread else screen_thread);
	if on_audio {
		c.on_audio, c.audio_on = on_audio, true;
		thread_init(*c.audio, audio_thread);
		c.audio.data = c;
		thread_start(*c.audio);
	}
	return c;
}

#scope_file

camera_count: s32 = -1; // unknown
screens: [..]Screen_Target;

wthumbs: struct {
	thread: Thread;
	started: bool;
	gen: int; // thumbs.gen when the list was taken
	windows: [..]Screen_Target; // ids only; read by the thread
};

target_hwnd :: (t: Screen_Target) -> HWND { return cast(HWND) cast(s64) cast(s32) t.id; } // HWNDs are 32-bit values, sign-extended

// src's rectangle scaled down to THUMB_W wide: RGBA on the heap, or empty.
thumb_from :: (src: HDC, x: int, y: int, w: int, h: int) -> []u8, int, int {
	if w <= 0 || h <= 0 return .[], 0, 0;
	tw, th := THUMB_W, clamp(THUMB_W * h / w, 2, THUMB_W * 2);
	mem := CreateCompatibleDC(src);
	bmp := CreateCompatibleBitmap(src, xx tw, xx th);
	old := SelectObject(mem, bmp);
	SetStretchBltMode(mem, .HALFTONE);
	ok := StretchBlt(mem, 0, 0, xx tw, xx th, src, xx x, xx y, xx w, xx h, .SRCCOPY) != .FALSE;
	SelectObject(mem, old);
	px := NewArray(tw * th * 4, u8);
	bmi: BITMAPINFO;
	bmi.bmiHeader = .{biSize = size_of(BITMAPINFOHEADER), biWidth = xx tw, biHeight = xx -th, biPlanes = 1, biBitCount = 32};
	ok = ok && GetDIBits(mem, bmp, 0, xx th, px.data, *bmi, DIB_RGB_COLORS) == th;
	DeleteObject(bmp);
	DeleteDC(mem);
	if !ok { array_free(px); return .[], 0, 0; }
	for i: 0..tw * th - 1 { p := px.data + i * 4; p[0], p[2], p[3] = p[2], p[0], 255; } // BGRX -> RGBA
	return px, tw, th;
}

// An activate's string attribute (IMFAttributes::GetAllocatedString), "" when missing.
act_string :: (act: *void, key: *GUID) -> string {
	s: *u16;
	len: u32;
	if mf.com(act, 13, #type (*void, *GUID, **u16, *u32) -> HRESULT #c_call)(act, key, *s, *len) < 0 return "";
	defer mf.CoTaskMemFree(s);
	out := wide_to_utf8(s, xx len);
	return out;
}

#scope_module

list_cameras :: () -> [..]Camera_Device {
	com := mf.com_enter();
	defer mf.com_leave(com);
	out: [..]Camera_Device;
	acts, n := cameras();
	for 0..n - 1 {
		array_add(*out, .{act_string(acts[it], *mf.MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK), act_string(acts[it], *mf.MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME)});
		mf.release(acts[it]);
	}
	if n mf.CoTaskMemFree(acts);
	return out;
}

#scope_file

// The video capture devices (release each, then CoTaskMemFree the array); updates camera_count.
cameras :: () -> **void, int {
	acts: **void;
	n: u32;
	attrs: *void;
	if mf.startup() && mf.MFCreateAttributes(*attrs, 1) >= 0 {
		mf.set_guid(attrs, *mf.MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE, *mf.MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID);
		if mf.MFEnumDeviceSources(attrs, *acts, *n) < 0 n = 0;
		mf.release(attrs);
	}
	atomic_store(*camera_count, cast(s32) n);
	return acts, n;
}

camera_thread :: (t: *Thread) -> s64 {
	c := cast(*Capture) t.data;
	com := mf.com_enter();
	defer mf.com_leave(com);
	acts, n := cameras();
	if !n { c.error = "No camera found."; return 0; }
	// Virtual cameras (NDI, for one) are root-enumerated, often listed before the real ones, and may
	// never deliver a frame until some app feeds them, so take the first real device.
	is_virtual :: (act: *void) -> bool {
		s: *u16;
		len: u32;
		if mf.com(act, 13, #type (*void, *GUID, **u16, *u32) -> HRESULT #c_call)(act, *mf.MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK, *s, *len) < 0 return false;
		defer mf.CoTaskMemFree(s);
		PREFIX :: "\\\\?\\root#";
		if len < PREFIX.count return false;
		for 0..PREFIX.count - 1 {
			ch := s[it];
			if ch >= #char "A" && ch <= #char "Z" ch += 32;
			if ch != PREFIX[it] return false;
		}
		return true;
	}
	pick := -1;
	if c.device for 0..n - 1 if act_string(acts[it], *mf.MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK,, temp) == c.device { pick = it; break; }
	if pick < 0 for 0..n - 1 if !is_virtual(acts[it]) { pick = it; break; }
	pick = max(pick, 0);
	act := acts[pick];
	for 0..n - 1 if it != pick mf.release(acts[it]);
	mf.CoTaskMemFree(acts);
	defer {
		mf.com(act, 34, #type (*void) -> HRESULT #c_call)(act); // IMFActivate::ShutdownObject
		mf.release(act);
	}
	source: *void;
	hr := mf.com(act, 33, #type (*void, *GUID, **void) -> HRESULT #c_call)(act, *mf.IID_IMFMediaSource, *source);
	if hr < 0 {
		log_error("camera: opening device % of % failed (hr %)", pick, n, hr);
		c.error = "Couldn't open the camera. Another app may be using it.";
		return 0;
	}
	attrs: *void;
	mf.MFCreateAttributes(*attrs, 2);
	if attrs {
		mf.set_u32(attrs, *mf.MF_SOURCE_READER_ENABLE_ADVANCED_VIDEO_PROCESSING, 1); // MJPG / YUY2 cameras -> NV12
		mf.set_u32(attrs, *mf.MF_LOW_LATENCY, 1);
	}
	reader: *void;
	hr = mf.MFCreateSourceReaderFromMediaSource(source, attrs, *reader);
	mf.release(attrs);
	mf.release(source);
	if hr < 0 {
		log_error("camera: source reader failed (hr %)", hr);
		c.error = "Couldn't open the camera.";
		return 0;
	}
	defer mf.release(reader);

	STREAM :: mf.MF_SOURCE_READER_FIRST_VIDEO_STREAM;
	set_type :: (reader: *void, t: *void) -> bool {
		return mf.com(reader, 7, #type (*void, u32, *u32, *void) -> HRESULT #c_call)(reader, STREAM, null, t) >= 0;
	}
	// The camera mode: at least the frame rate, then the closest height, then NV12 (no conversion).
	best: *void;
	best_score := 1 << 62;
	for i: 0..999 {
		nt: *void;
		if mf.com(reader, 5, #type (*void, u32, u32, **void) -> HRESULT #c_call)(reader, STREAM, xx i, *nt) < 0 break;
		w, h := mf.unpair(mf.get_u64(nt, *mf.MF_MT_FRAME_SIZE));
		num, den := mf.unpair(mf.get_u64(nt, *mf.MF_MT_FRAME_RATE));
		score := max(h - c.height, c.height - h) * 10 +(ifx mf.has_subtype(nt, *mf.MFVideoFormat_NV12) then 0 else 1);
		if num < c.fps * max(den, 1) score += 1_000_000;
		if w * 9 != h * 16 score += 2;
		if score < best_score { mf.release(best); best, best_score = nt, score; }
		else mf.release(nt);
	}
	w, h := c.width, c.height;
	if best {
		set_type(reader, best);
		w, h = mf.unpair(mf.get_u64(best, *mf.MF_MT_FRAME_SIZE));
		mf.release(best);
	}
	out := mf.video_type(*mf.MFVideoFormat_NV12, w, h);
	ok := out && set_type(reader, out);
	mf.release(out);
	if !ok {
		log_error("camera: no NV12 output at %x%", w, h);
		c.error = "The camera's video format isn't supported.";
		return 0;
	}

	// The current output type: visible size, padded height and stride.
	read_type :: (reader: *void) -> int, int, int, int {
		cur: *void;
		if mf.com(reader, 6, #type (*void, u32, **void) -> HRESULT #c_call)(reader, STREAM, *cur) < 0 return 0, 0, 0, 0;
		defer mf.release(cur);
		w, h, pad_h := mf.visible_size(cur);
		return w, h, pad_h, cast(s32) mf.get_u32(cur, *mf.MF_MT_DEFAULT_STRIDE);
	}
	frame_w, frame_h, pad_h, stride := read_type(reader);
	while !atomic_load(*c.quit) {
		idx, flags: u32;
		ts: s64;
		s: *void;
		hr = mf.com(reader, 9, #type (*void, u32, u32, *u32, *u32, *s64, **void) -> HRESULT #c_call)(reader, STREAM, 0, *idx, *flags, *ts, *s);
		if hr < 0 || flags & (mf.MF_SOURCE_READERF_ERROR | mf.MF_SOURCE_READERF_ENDOFSTREAM) {
			log_error("camera: capture stopped (hr %, flags %)", hr, flags);
			c.error = "The camera stopped. Another app may have taken it.";
			mf.release(s);
			break;
		}
		if flags & mf.MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED frame_w, frame_h, pad_h, stride = read_type(reader);
		if !s continue;
		f := mf.nv12_from_sample(s, frame_w, frame_h, pad_h, stride);
		mf.release(s);
		if f { emit(c, f); yuv.nv12_release(f); }
	}
	return 0;
}

DXGI_ERROR_ACCESS_LOST :: cast(HRESULT) 0x887A0026;
DXGI_ERROR_WAIT_TIMEOUT :: cast(HRESULT) 0x887A0027;

screen_thread :: (t: *Thread) -> s64 {
	c := cast(*Capture) t.data;
	last: *yuv.Nv12;
	defer yuv.nv12_release(last);
	// A session lasts until the duplication is lost (mode change, secure desktop, display off).
	while !atomic_load(*c.quit) {
		if !screen_session(c, *last) && !atomic_load(*c.quit) {
			if last emit(c, last);
			sleep_milliseconds(250);
		}
	}
	return 0;
}

screen_session :: (c: *Capture, last: **yuv.Nv12) -> bool {
	factory: *IDXGIFactory1;
	if FAILED(CreateDXGIFactory1(uid(IDXGIFactory1_UUID), cast(**void) *factory)) return false;
	defer IUnknown_Release(factory);
	adapter: *IDXGIAdapter1;
	if FAILED(IDXGIFactory1_EnumAdapters1(factory, c.target.id >> 8, *adapter)) return false;
	defer IUnknown_Release(adapter);
	output: *IDXGIOutput;
	if FAILED(IDXGIAdapter_EnumOutputs(adapter, c.target.id & 0xFF, *output)) return false;
	defer IUnknown_Release(output);
	output1: *IDXGIOutput1;
	if FAILED(IUnknown_QueryInterface(output, *uid(IDXGIOutput1_UUID), cast(**void) *output1)) return false;
	defer IUnknown_Release(output1);

	dev: *ID3D11Device;
	ctx: *ID3D11DeviceContext;
	if FAILED(D3D11CreateDevice(adapter, .UNKNOWN, null, .BGRA_SUPPORT | .VIDEO_SUPPORT, null, 0, D3D11_SDK_VERSION, *dev, null, *ctx)) return false;
	defer { IUnknown_Release(ctx); IUnknown_Release(dev); }
	dup: *IDXGIOutputDuplication;
	if FAILED(IDXGIOutput1_DuplicateOutput(output1, dev, *dup)) return false;
	defer IUnknown_Release(dup);
	dd: DXGI_OUTDUPL_DESC;
	IDXGIOutputDuplication_GetDesc(dup, *dd);
	cv: Converter;
	defer converter_free(*cv);
	if !converter_init(*cv, c, dev, ctx, dd.ModeDesc.Width, dd.ModeDesc.Height) return false;

	// Duplication leaves the cursor out: desk keeps the screen's last image, and each frame copies it to
	// drawn, a GDI-compatible texture, and draws the cursor there.
	td := D3D11_TEXTURE2D_DESC.{Width = dd.ModeDesc.Width, Height = dd.ModeDesc.Height, MipLevels = 1, ArraySize = 1, Format = .B8G8R8A8_UNORM,
		SampleDesc = .{Count = 1}, Usage = .DEFAULT, BindFlags = .RENDER_TARGET, MiscFlags = .GDI_COMPATIBLE};
	drawn, desk: *ID3D11Texture2D;
	if FAILED(ID3D11Device_CreateTexture2D(dev, *td, null, *drawn)) return false;
	defer IUnknown_Release(drawn);
	td.BindFlags, td.MiscFlags = 0, 0;
	if FAILED(ID3D11Device_CreateTexture2D(dev, *td, null, *desk)) return false;
	defer IUnknown_Release(desk);
	surface: *IDXGISurface1;
	if FAILED(IUnknown_QueryInterface(drawn, *uid(IDXGISurface1_UUID), cast(**void) *surface)) return false;
	defer IUnknown_Release(surface);

	have := false; // desk holds an image
	period_ns := 1_000_000_000 / c.fps;
	next := current_time_monotonic();
	while !atomic_load(*c.quit) {
		wait := to_nanoseconds(next - current_time_monotonic());
		if wait > 0 sleep_milliseconds(cast(s32) (wait / 1_000_000));
		next += nanoseconds_to_apollo(period_ns);
		if next < current_time_monotonic() next = current_time_monotonic();

		info: DXGI_OUTDUPL_FRAME_INFO;
		res: *IDXGIResource;
		hr := IDXGIOutputDuplication_AcquireNextFrame(dup, 0, *info, *res);
		if hr == DXGI_ERROR_ACCESS_LOST return false;
		if FAILED(hr) && hr != DXGI_ERROR_WAIT_TIMEOUT return false;
		if SUCCEEDED(hr) {
			// LastPresentTime is 0 when only the pointer moved: the last image still stands.
			fresh := info.LastPresentTime.QuadPart != 0 || !have;
			tex: *ID3D11Texture2D;
			if fresh && SUCCEEDED(IUnknown_QueryInterface(res, *uid(ID3D11Texture2D_UUID), cast(**void) *tex)) {
				ID3D11DeviceContext_CopyResource(ctx, desk, tex);
				IUnknown_Release(tex);
				have = true;
			}
			IUnknown_Release(res);
			IDXGIOutputDuplication_ReleaseFrame(dup);
			if have && (fresh || info.LastMouseUpdateTime.QuadPart != 0) {
				ID3D11DeviceContext_CopyResource(ctx, drawn, desk);
				draw_cursor(surface, c.target.x, c.target.y);
				f := convert(*cv, c, ctx, drawn);
				if f { yuv.nv12_release(last.*); last.* = f; }
			}
		}
		// Static screens produce no new images; repeat the last so keyframe requests and late viewers get one.
		if last.* emit(c, last.*);
	}
	return true;
}

// The cursor as Windows draws it, at its place on the screen whose top left is (x0, y0) on the desktop.
draw_cursor :: (surface: *IDXGISurface1, x0: int, y0: int) {
	ci := CURSORINFO.{cbSize = size_of(CURSORINFO)};
	if !GetCursorInfo(*ci) || !(ci.flags & CURSOR_SHOWING) || !ci.hCursor return;
	ii: ICONINFO;
	if GetIconInfo(ci.hCursor, *ii) == .FALSE return;
	if ii.hbmMask DeleteObject(ii.hbmMask);
	if ii.hbmColor DeleteObject(ii.hbmColor);
	dc: HDC;
	if FAILED(IDXGISurface1_GetDC(surface, .FALSE, *dc)) return;
	DrawIconEx(dc, xx (ci.ptScreenPos.x - x0 - ii.xHotspot), xx (ci.ptScreenPos.y - y0 - ii.yHotspot), ci.hCursor, 0, 0, 0, null, DI_NORMAL);
	IDXGISurface1_ReleaseDC(surface, null);
}

// The D3D11 video processor: a BGRA texture of in_w x in_h scaled into the capture's NV12 size (fitted
// inside it, black bars around) and read back.
Converter :: struct {
	vdev: *ID3D11VideoDevice;
	vctx: *ID3D11VideoContext;
	venum: *ID3D11VideoProcessorEnumerator;
	vp: *ID3D11VideoProcessor;
	nv12, staging: *ID3D11Texture2D;
	oview: *ID3D11VideoProcessorOutputView;
	in_w, in_h: u32;
}

converter_init :: (cv: *Converter, c: *Capture, dev: *ID3D11Device, ctx: *ID3D11DeviceContext, in_w: u32, in_h: u32) -> bool {
	cv.in_w, cv.in_h = in_w, in_h;
	if FAILED(IUnknown_QueryInterface(dev, *uid(ID3D11VideoDevice_UUID), cast(**void) *cv.vdev)) return false;
	if FAILED(IUnknown_QueryInterface(ctx, *uid(ID3D11VideoContext_UUID), cast(**void) *cv.vctx)) return false;
	rate := DXGI_RATIONAL.{xx c.fps, 1};
	content := D3D11_VIDEO_PROCESSOR_CONTENT_DESC.{
		InputFrameFormat = .PROGRESSIVE, InputFrameRate = rate, InputWidth = in_w, InputHeight = in_h,
		OutputFrameRate = rate, OutputWidth = xx c.width, OutputHeight = xx c.height, Usage = .OPTIMAL_SPEED,
	};
	if FAILED(ID3D11VideoDevice_CreateVideoProcessorEnumerator(cv.vdev, *content, *cv.venum)) return false;
	if FAILED(ID3D11VideoDevice_CreateVideoProcessor(cv.vdev, cv.venum, 0, *cv.vp)) return false;
	// Bits: Usage, RGB_Range (0 = full), YCbCr_Matrix (1 = BT.709), YCbCr_xvYCC, Nominal_Range (2 bits, 1 = 16-235).
	// The matrix follows media's guess on the receiving side: BT.709 from 720 lines up.
	in_cs := D3D11_VIDEO_PROCESSOR_COLOR_SPACE.{0};
	out_cs := D3D11_VIDEO_PROCESSOR_COLOR_SPACE.{cast(u32) ((1 << 4) | (ifx c.height >= 720 then 1 << 2 else 0))};
	ID3D11VideoContext_VideoProcessorSetStreamColorSpace(cv.vctx, cv.vp, 0, *in_cs);
	ID3D11VideoContext_VideoProcessorSetOutputColorSpace(cv.vctx, cv.vp, *out_cs);
	ID3D11VideoContext_VideoProcessorSetStreamFrameFormat(cv.vctx, cv.vp, 0, .PROGRESSIVE);
	s := min(c.width / cast(float) in_w, c.height / cast(float) in_h);
	dw, dh := min(cast(s32) (in_w * s + 0.5), cast(s32) c.width), min(cast(s32) (in_h * s + 0.5), cast(s32) c.height);
	dst := RECT.{(cast(s32) c.width - dw) / 2, (cast(s32) c.height - dh) / 2, 0, 0};
	dst.right, dst.bottom = dst.left + dw, dst.top + dh;
	ID3D11VideoContext_VideoProcessorSetStreamDestRect(cv.vctx, cv.vp, 0, .TRUE, *dst);
	black: D3D11_VIDEO_COLOR;
	black.RGBA = .{0, 0, 0, 1};
	ID3D11VideoContext_VideoProcessorSetOutputBackgroundColor(cv.vctx, cv.vp, .FALSE, *black);

	td := D3D11_TEXTURE2D_DESC.{Width = xx c.width, Height = xx c.height, MipLevels = 1, ArraySize = 1, Format = .NV12, SampleDesc = .{Count = 1}, Usage = .DEFAULT, BindFlags = .RENDER_TARGET};
	if FAILED(ID3D11Device_CreateTexture2D(dev, *td, null, *cv.nv12)) return false;
	td.Usage = .STAGING;
	td.BindFlags = 0;
	td.CPUAccessFlags = .READ;
	if FAILED(ID3D11Device_CreateTexture2D(dev, *td, null, *cv.staging)) return false;
	ovd := D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC.{ViewDimension = .TEXTURE2D};
	return SUCCEEDED(ID3D11VideoDevice_CreateVideoProcessorOutputView(cv.vdev, cv.nv12, cv.venum, *ovd, *cv.oview));
}

converter_free :: (cv: *Converter) {
	for (*void).[cv.oview, cv.staging, cv.nv12, cv.vp, cv.venum, cv.vctx, cv.vdev] mf.release(it);
	cv.* = .{};
}

convert :: (cv: *Converter, c: *Capture, ctx: *ID3D11DeviceContext, tex: *ID3D11Texture2D) -> *yuv.Nv12 {
	ivd := D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC.{ViewDimension = .TEXTURE2D};
	iview: *ID3D11VideoProcessorInputView;
	if FAILED(ID3D11VideoDevice_CreateVideoProcessorInputView(cv.vdev, tex, cv.venum, *ivd, *iview)) return null;
	stream := D3D11_VIDEO_PROCESSOR_STREAM.{Enable = 1, pInputSurface = iview};
	hr := ID3D11VideoContext_VideoProcessorBlt(cv.vctx, cv.vp, cv.oview, 0, 1, *stream);
	IUnknown_Release(iview);
	if FAILED(hr) return null;
	ID3D11DeviceContext_CopyResource(ctx, cv.staging, cv.nv12);
	m: D3D11_MAPPED_SUBRESOURCE;
	if FAILED(ID3D11DeviceContext_Map(ctx, cv.staging, 0, .READ, 0, *m)) return null;
	p := cast(*u8) m.pData;
	pitch := cast(int) m.RowPitch;
	f := yuv.nv12_from_planes(c.width, c.height, p, p + pitch * c.height, pitch);
	ID3D11DeviceContext_Unmap(ctx, cv.staging, 0);
	return f;
}

// A window through Windows.Graphics.Capture: a free-threaded frame pool polled at fps, the newest frame
// scaled like a screen's. The window may be resized (the pool follows, the stream keeps its size) and ends
// the capture when it closes.
window_thread :: (t: *Thread) -> s64 {
	c := cast(*Capture) t.data;
	com := mf.com_enter();
	defer mf.com_leave(com);
	c.error = "This window can't be captured.";
	hwnd := target_hwnd(c.target);
	dev: *ID3D11Device;
	ctx: *ID3D11DeviceContext;
	if FAILED(D3D11CreateDevice(null, .HARDWARE, null, .BGRA_SUPPORT | .VIDEO_SUPPORT, null, 0, D3D11_SDK_VERSION, *dev, null, *ctx)) return 0;
	defer { IUnknown_Release(ctx); IUnknown_Release(dev); }
	rdev: *void; // IDirect3DDevice
	dxgi := mf.query(dev, *uid(IDXGIDevice_UUID));
	if dxgi {
		insp: *void;
		CreateDirect3D11DeviceFromDXGIDevice(dxgi, *insp);
		mf.release(dxgi);
		if insp { rdev = mf.query(insp, *IID_IDirect3DDevice); mf.release(insp); }
	}
	defer mf.release(rdev);
	item: *void; // GraphicsCaptureItem
	interop := activation_factory("Windows.Graphics.Capture.GraphicsCaptureItem", *IID_IGraphicsCaptureItemInterop);
	if interop {
		mf.com(interop, 3, #type (*void, HWND, *GUID, **void) -> HRESULT #c_call)(interop, hwnd, *IID_IGraphicsCaptureItem, *item); // CreateForWindow
		mf.release(interop);
	}
	defer mf.release(item);
	statics := activation_factory("Windows.Graphics.Capture.Direct3D11CaptureFramePool", *IID_IDirect3D11CaptureFramePoolStatics2);
	defer mf.release(statics);
	if !rdev || !item || !statics { log_error("window capture: unavailable (device %, item %, pool %)", rdev != null, item != null, statics != null); return 0; }
	size: u64; // SizeInt32: width in the low half
	mf.com(item, 7, #type (*void, *u64) -> HRESULT #c_call)(item, *size); // get_Size
	pool: *void;
	mf.com(statics, 6, #type (*void, *void, s32, s32, u64, **void) -> HRESULT #c_call)(statics, rdev, BGRA8, 2, size, *pool); // CreateFreeThreaded
	if !pool return 0;
	defer { winrt_close(pool); mf.release(pool); }
	session: *void;
	mf.com(pool, 10, #type (*void, *void, **void) -> HRESULT #c_call)(pool, item, *session); // CreateCaptureSession
	if !session return 0;
	defer { winrt_close(session); mf.release(session); }
	// No yellow border where Windows lets it go (Windows 11).
	s3 := mf.query(session, *IID_IGraphicsCaptureSession3);
	if s3 { mf.com(s3, 7, #type (*void, u8) -> HRESULT #c_call)(s3, 0); mf.release(s3); } // put_IsBorderRequired
	if mf.com(session, 6, #type (*void) -> HRESULT #c_call)(session) < 0 return 0; // StartCapture
	c.error = "";

	cv: Converter;
	defer converter_free(*cv);
	last: *yuv.Nv12;
	defer yuv.nv12_release(last);
	period_ns := 1_000_000_000 / c.fps;
	next := current_time_monotonic();
	while !atomic_load(*c.quit) {
		wait := to_nanoseconds(next - current_time_monotonic());
		if wait > 0 sleep_milliseconds(cast(s32) (wait / 1_000_000));
		next += nanoseconds_to_apollo(period_ns);
		if next < current_time_monotonic() next = current_time_monotonic();
		if !IsWindow(hwnd) { c.error = "The window was closed."; break; }

		frame: *void;
		mf.com(pool, 7, #type (*void, **void) -> HRESULT #c_call)(pool, *frame); // TryGetNextFrame
		if frame {
			cs: u64;
			mf.com(frame, 8, #type (*void, *u64) -> HRESULT #c_call)(frame, *cs); // get_ContentSize
			if cs != size && (cs & 0xFFFF_FFFF) && (cs >> 32) {
				// Resized: frames come at the new size once the pool is remade.
				size = cs;
				mf.com(pool, 6, #type (*void, *void, s32, s32, u64) -> HRESULT #c_call)(pool, rdev, BGRA8, 2, size); // Recreate
			} else {
				surf: *void;
				mf.com(frame, 6, #type (*void, **void) -> HRESULT #c_call)(frame, *surf); // get_Surface
				access := ifx surf then mf.query(surf, *IID_IDirect3DDxgiInterfaceAccess);
				tex: *ID3D11Texture2D;
				if access mf.com(access, 3, #type (*void, *GUID, **void) -> HRESULT #c_call)(access, *uid(ID3D11Texture2D_UUID), cast(**void) *tex); // GetInterface
				if tex {
					td: D3D11_TEXTURE2D_DESC;
					ID3D11Texture2D_GetDesc(tex, *td);
					if td.Width != cv.in_w || td.Height != cv.in_h {
						converter_free(*cv);
						if !converter_init(*cv, c, dev, ctx, td.Width, td.Height) converter_free(*cv);
					}
					f := ifx cv.vp then convert(*cv, c, ctx, tex);
					if f { yuv.nv12_release(last); last = f; }
					IUnknown_Release(tex);
				}
				mf.release(access);
				mf.release(surf);
			}
			winrt_close(frame);
			mf.release(frame);
		}
		// A still window sends no frames; repeat the last so keyframe requests and late viewers get one.
		if last emit(c, last);
	}
	return 0;
}

BGRA8 :: 87; // DirectXPixelFormat.B8G8R8A8UIntNormalized

winrt_close :: (obj: *void) {
	cl := mf.query(obj, *IID_IClosable);
	if cl { mf.com(cl, 6, #type (*void) -> HRESULT #c_call)(cl); mf.release(cl); }
}

// combase's WinRT entry points have no import library in the SDK, so they're looked up.
activation_factory :: (class: string, iid: *GUID) -> *void {
	lib := LoadLibraryA("combase.dll");
	if !lib return null;
	create := cast(#type (s: *u16, n: u32, out: **void) -> HRESULT #c_call) GetProcAddress(lib, "WindowsCreateString");
	delete := cast(#type (s: *void) -> HRESULT #c_call) GetProcAddress(lib, "WindowsDeleteString");
	factory := cast(#type (class: *void, iid: *GUID, out: **void) -> HRESULT #c_call) GetProcAddress(lib, "RoGetActivationFactory");
	if !create || !delete || !factory return null;
	hs: *void; // HSTRING
	if create(utf8_to_wide(class,, temp), xx class.count, *hs) < 0 return null;
	defer delete(hs);
	f: *void;
	if factory(hs, iid, *f) < 0 return null;
	return f;
}

// Soundshare: WASAPI process loopback (Windows 10 2004+), interleaved stereo float 48 kHz, on a thread of its own. A
// screen's sound is everything but fastcord's own process tree, so the call's voices and fastcord's sounds
// stay out; a window's is only its app's process tree.
audio_thread :: (t: *Thread) -> s64 {
	c := cast(*Capture) t.data;
	com := mf.com_enter();
	defer mf.com_leave(com);
	params := Loopback_Params.{type = 1, pid = GetCurrentProcessId(), mode = 1}; // PROCESS_LOOPBACK, EXCLUDE_TARGET_PROCESS_TREE
	if c.target.is_window {
		params.pid = 0;
		GetWindowThreadProcessId(target_hwnd(c.target), *params.pid);
		params.mode = 0; // INCLUDE_TARGET_PROCESS_TREE
		if !params.pid return 0;
	}
	blob := Blob_Variant.{vt = 65, size = size_of(Loopback_Params), data = *params}; // VT_BLOB
	handler := Activate_Handler.{vtbl = *activate_vtbl, done = CreateEventW(null, 1, 0, null)};
	defer CloseHandle(handler.done);
	op: *void;
	hr := ActivateAudioInterfaceAsync(utf8_to_wide("VAD\\Process_Loopback",, temp), *IID_IAudioClient, *blob, *handler, *op);
	if hr < 0 { log_error("soundshare: activation failed (hr %)", hr); return 0; }
	WaitForSingleObject(handler.done, INFINITE);
	result: HRESULT;
	client: *void;
	mf.com(op, 3, #type (*void, *HRESULT, **void) -> HRESULT #c_call)(op, *result, *client); // GetActivateResult
	mf.release(op);
	if result < 0 || !client { log_error("soundshare: activation failed (hr %)", result); mf.release(client); return 0; }
	defer mf.release(client);

	// The engine converts to what is asked (AUTOCONVERTPCM): stereo if it will, else mono copied to both channels.
	LOOPBACK :: 0x0002_0000;
	EVENTCALLBACK :: 0x0004_0000;
	AUTOCONVERTPCM :: 0x8000_0000;
	SRC_DEFAULT_QUALITY :: 0x0800_0000;
	channels: u16;
	for ch: u16.[2, 1] {
		f := WAVEFORMATEX.{wFormatTag = 3, nChannels = ch, nSamplesPerSec = 48000, nAvgBytesPerSec = 48000 * 4 * cast(u32) ch, nBlockAlign = 4 * ch, wBitsPerSample = 32}; // IEEE float
		hr = mf.com(client, 3, #type (*void, u32, u32, s64, s64, *WAVEFORMATEX, *void) -> HRESULT #c_call)(client, 0, LOOPBACK | EVENTCALLBACK | AUTOCONVERTPCM | SRC_DEFAULT_QUALITY, 2_000_000, 0, *f, null); // Initialize: shared, 200 ms
		if hr >= 0 { channels = ch; break; }
	}
	if !channels { log_error("soundshare: initialize failed (hr %)", hr); return 0; }
	event := CreateEventW(null, 0, 0, null);
	defer CloseHandle(event);
	mf.com(client, 13, #type (*void, HANDLE) -> HRESULT #c_call)(client, event); // SetEventHandle
	cap: *void;
	mf.com(client, 14, #type (*void, *GUID, **void) -> HRESULT #c_call)(client, *IID_IAudioCaptureClient, *cap); // GetService
	if !cap return 0;
	defer mf.release(cap);
	if mf.com(client, 10, #type (*void) -> HRESULT #c_call)(client) < 0 return 0; // Start
	defer mf.com(client, 11, #type (*void) -> HRESULT #c_call)(client); // Stop

	while !atomic_load(*c.quit) {
		WaitForSingleObject(event, 100);
		for 1..64 { // the packets waiting, at most
			data: *float32;
			n, flags: u32;
			hr = mf.com(cap, 3, #type (*void, **float32, *u32, *u32, *u64, *u64) -> HRESULT #c_call)(cap, *data, *n, *flags, null, null); // GetBuffer
			if hr < 0 { log_error("soundshare: stopped (hr %)", hr); return 0; }
			if hr == AUDCLNT_S_BUFFER_EMPTY break;
			pcm := NewArray(min(n, 48000) * 2, float32,, temp);
			if !(flags & 2) for 0..pcm.count - 1 pcm[it] = ifx channels == 2 then data[it] else data[it / 2]; // 2: SILENT
			mf.com(cap, 4, #type (*void, u32) -> HRESULT #c_call)(cap, n); // ReleaseBuffer
			locks.lock(*c.mu);
			if !atomic_load(*c.quit) && pcm.count c.on_audio(c.user, pcm);
			locks.unlock(*c.mu);
			reset_temporary_storage();
		}
	}
	return 0;
}

AUDCLNT_S_BUFFER_EMPTY :: cast(HRESULT) 0x0889_0001;

Loopback_Params :: struct { type: u32; pid: u32; mode: u32; } // AUDIOCLIENT_ACTIVATION_PARAMS
Blob_Variant :: struct { vt: u16; reserved: [3]u16; size: u32; data: *void; } // a PROPVARIANT holding a BLOB

WAVEFORMATEX :: struct {
	wFormatTag: u16;
	nChannels: u16;
	nSamplesPerSec: u32;
	nAvgBytesPerSec: u32;
	nBlockAlign: u16;
	wBitsPerSample: u16;
	cbSize: u16;
} #no_padding

// IActivateAudioInterfaceCompletionHandler, agile (ActivateAudioInterfaceAsync requires it): signals done.
Activate_Handler :: struct {
	vtbl: *Activate_Vtbl;
	done: HANDLE;
}

Activate_Vtbl :: struct {
	QueryInterface: (this: *void, riid: *GUID, out: **void) -> HRESULT #c_call;
	AddRef, Release: (this: *void) -> u32 #c_call;
	ActivateCompleted: (this: *Activate_Handler, op: *void) -> HRESULT #c_call;
}

activate_vtbl := Activate_Vtbl.{
	QueryInterface = (this: *void, riid: *GUID, out: **void) -> HRESULT #c_call {
		// IUnknown {00000000-...-C000-000000000046}, IActivateAudioInterfaceCompletionHandler {41D949AB-...}, IAgileObject {94EA2B94-...}
		if riid && ((riid.Data1 == 0 && riid.Data4[0] == 0xC0) || riid.Data1 == 0x41D949AB || riid.Data1 == 0x94EA2B94) {
			out.* = this;
			return 0;
		}
		out.* = null;
		return cast,no_check(HRESULT) 0x8000_4002; // E_NOINTERFACE
	},
	AddRef = (this: *void) -> u32 #c_call { return 1; },
	Release = (this: *void) -> u32 #c_call { return 1; },
	ActivateCompleted = (this: *Activate_Handler, op: *void) -> HRESULT #c_call { SetEvent(this.done); return 0; },
};

IID_IAudioClient := GUID.{0x1CB9AD4C, 0xDBFA, 0x4C32, .[0xB1, 0x78, 0xC2, 0xF5, 0x68, 0xA7, 0x03, 0xB2]};
IID_IAudioCaptureClient := GUID.{0xC8ADBD64, 0xE71E, 0x48A0, .[0xA4, 0xDE, 0x18, 0x5C, 0x39, 0x5C, 0xD3, 0x17]};
IID_IDirect3DDevice := GUID.{0xA37624AB, 0x8D5F, 0x4650, .[0x9D, 0x3E, 0x9E, 0xAE, 0x3D, 0x9B, 0xC6, 0x70]};
IID_IDirect3DDxgiInterfaceAccess := GUID.{0xA9B3D012, 0x3DF2, 0x4EE3, .[0xB8, 0xD1, 0x86, 0x95, 0xF4, 0x57, 0xD3, 0xC1]};
IID_IGraphicsCaptureItemInterop := GUID.{0x3628E81B, 0x3CAC, 0x4C60, .[0xB7, 0xF4, 0x23, 0xCE, 0x0E, 0x0C, 0x33, 0x56]};
IID_IGraphicsCaptureItem := GUID.{0x79C3F95B, 0x31F7, 0x4EC2, .[0xA4, 0x64, 0x63, 0x2E, 0xF5, 0xD3, 0x07, 0x60]};
IID_IDirect3D11CaptureFramePoolStatics2 := GUID.{0x589B103F, 0x6BBC, 0x5DF5, .[0xA9, 0x91, 0x02, 0xE2, 0x8B, 0x3B, 0x66, 0xD5]};
IID_IGraphicsCaptureSession3 := GUID.{0xF2CDD966, 0x22AE, 0x5EA1, .[0x95, 0x96, 0x3A, 0x28, 0x93, 0x44, 0xC3, 0xBE]};
IID_IClosable := GUID.{0x30D5A829, 0x7FA4, 0x4026, .[0x83, 0xBB, 0xD7, 0x5B, 0xAE, 0x4E, 0xA9, 0x9E]};

CURSORINFO :: struct { cbSize: u32; flags: u32; hCursor: HCURSOR; ptScreenPos: POINT; }
CURSOR_SHOWING :: 1;
DI_NORMAL :: 3;
PW_RENDERFULLCONTENT :: 2;
GW_HWNDNEXT :: 2;
GW_OWNER :: 4;
GWL_EXSTYLE :: -20;
WS_EX_TOOLWINDOW :: 0x80;
DWMWA_EXTENDED_FRAME_BOUNDS :: 9;
DWMWA_CLOAKED :: 14;

user32_ :: #system_library "user32";
dwmapi :: #system_library "dwmapi";
mmdevapi :: #system_library "mmdevapi";
d3d11_ :: #system_library "d3d11";
GetCursorInfo :: (ci: *CURSORINFO) -> s32 #foreign user32_;
DrawIconEx :: (dc: HDC, x: s32, y: s32, icon: HICON, w: s32, h: s32, step: u32, brush: *void, flags: u32) -> s32 #foreign user32_;
GetTopWindow :: (hwnd: HWND) -> HWND #foreign user32_;
GetWindow :: (hwnd: HWND, cmd: u32) -> HWND #foreign user32_;
GetShellWindow :: () -> HWND #foreign user32_;
IsWindow :: (hwnd: HWND) -> s32 #foreign user32_;
SetEvent :: (event: HANDLE) -> s32 #foreign kernel32;
IsWindowVisible :: (hwnd: HWND) -> s32 #foreign user32_;
IsIconic :: (hwnd: HWND) -> s32 #foreign user32_;
IsHungAppWindow :: (hwnd: HWND) -> s32 #foreign user32_;
GetWindowTextW :: (hwnd: HWND, buf: *u16, n: s32) -> s32 #foreign user32_;
GetWindowThreadProcessId :: (hwnd: HWND, pid: *u32) -> u32 #foreign user32_;
DwmGetWindowAttribute :: (hwnd: HWND, attr: u32, out: *void, size: u32) -> HRESULT #foreign dwmapi;
ActivateAudioInterfaceAsync :: (path: *u16, iid: *GUID, params: *Blob_Variant, handler: *Activate_Handler, op: **void) -> HRESULT #foreign mmdevapi;
CreateDirect3D11DeviceFromDXGIDevice :: (dxgi: *void, out: **void) -> HRESULT #foreign d3d11_;
