// Camera capture (Media Foundation source reader) and screen capture (DXGI desktop duplication, scaled
// and converted to NV12 by the D3D11 video processor). Each capture runs on its own thread, which opens
// the device too, so starting one never blocks the caller. Frames are yuv.Nv12.

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

// Screens only (desktop duplication can't capture a single window), listed synchronously: DXGI's
// enumeration is fast and touches neither disk nor network.
screen_targets_refresh :: () {
	for screens free(it.name);
	screens.count = 0;
	factory: *IDXGIFactory1;
	if FAILED(CreateDXGIFactory1(uid(IDXGIFactory1_UUID), cast(**void) *factory)) return;
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
	// thumbnails: each screen scaled down by GDI, a few milliseconds each
	thumbs_clear();
	screen := GetDC(null);
	defer ReleaseDC(null, screen);
	for screens {
		if it.width <= 0 || it.height <= 0 continue;
		w, h := THUMB_W, clamp(THUMB_W * it.height / it.width, 2, THUMB_W * 2);
		mem := CreateCompatibleDC(screen);
		bmp := CreateCompatibleBitmap(screen, xx w, xx h);
		old := SelectObject(mem, bmp);
		SetStretchBltMode(mem, .HALFTONE);
		ok := StretchBlt(mem, 0, 0, xx w, xx h, screen, xx it.x, xx it.y, xx it.width, xx it.height, .SRCCOPY) != .FALSE;
		SelectObject(mem, old);
		px := NewArray(w * h * 4, u8);
		bmi: BITMAPINFO;
		bmi.bmiHeader = .{biSize = size_of(BITMAPINFOHEADER), biWidth = xx w, biHeight = xx -h, biPlanes = 1, biBitCount = 32};
		ok = ok && GetDIBits(mem, bmp, 0, xx h, px.data, *bmi, DIB_RGB_COLORS) == h;
		DeleteObject(bmp);
		DeleteDC(mem);
		if !ok { array_free(px); continue; }
		for i: 0..w * h - 1 { p := px.data + i * 4; p[0], p[2], p[3] = p[2], p[0], 255; } // BGRX -> RGBA
		thumb_add(false, it.id, px, w, h);
	}
}

screen_targets :: () -> []Screen_Target, ready: bool { return screens, true; }

screen_start :: (target: Screen_Target, on_frame: Frame_Proc, user: *void, fps := 30, max_height := 1080) -> *Capture {
	c := New(Capture);
	w, h := max(target.width, 2), max(target.height, 2);
	if h > max_height { w = w * max_height / h; h = max_height; }
	c.* = .{on_frame = on_frame, user = user, width = w & ~1, height = h & ~1, fps = max(fps, 1), target = target};
	c.target.name = "";
	start(c, screen_thread);
	return c;
}

#scope_file

camera_count: s32 = -1; // unknown
screens: [..]Screen_Target;

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
		print("camera: opening device % of % failed (hr %)\n", pick, n, hr, to_standard_error = true);
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
		print("camera: source reader failed (hr %)\n", hr, to_standard_error = true);
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
		print("camera: no NV12 output at %x%\n", w, h, to_standard_error = true);
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
			print("camera: capture stopped (hr %, flags %)\n", hr, flags, to_standard_error = true);
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

	vdev: *ID3D11VideoDevice;
	vctx: *ID3D11VideoContext;
	if FAILED(IUnknown_QueryInterface(dev, *uid(ID3D11VideoDevice_UUID), cast(**void) *vdev)) return false;
	defer IUnknown_Release(vdev);
	if FAILED(IUnknown_QueryInterface(ctx, *uid(ID3D11VideoContext_UUID), cast(**void) *vctx)) return false;
	defer IUnknown_Release(vctx);
	rate := DXGI_RATIONAL.{xx c.fps, 1};
	content := D3D11_VIDEO_PROCESSOR_CONTENT_DESC.{
		InputFrameFormat = .PROGRESSIVE, InputFrameRate = rate, InputWidth = dd.ModeDesc.Width, InputHeight = dd.ModeDesc.Height,
		OutputFrameRate = rate, OutputWidth = xx c.width, OutputHeight = xx c.height, Usage = .OPTIMAL_SPEED,
	};
	venum: *ID3D11VideoProcessorEnumerator;
	if FAILED(ID3D11VideoDevice_CreateVideoProcessorEnumerator(vdev, *content, *venum)) return false;
	defer IUnknown_Release(venum);
	vp: *ID3D11VideoProcessor;
	if FAILED(ID3D11VideoDevice_CreateVideoProcessor(vdev, venum, 0, *vp)) return false;
	defer IUnknown_Release(vp);
	// Bits: Usage, RGB_Range (0 = full), YCbCr_Matrix (1 = BT.709), YCbCr_xvYCC, Nominal_Range (2 bits, 1 = 16-235).
	// The matrix follows media's guess on the receiving side: BT.709 from 720 lines up.
	in_cs := D3D11_VIDEO_PROCESSOR_COLOR_SPACE.{0};
	out_cs := D3D11_VIDEO_PROCESSOR_COLOR_SPACE.{cast(u32) ((1 << 4) | (ifx c.height >= 720 then 1 << 2 else 0))};
	ID3D11VideoContext_VideoProcessorSetStreamColorSpace(vctx, vp, 0, *in_cs);
	ID3D11VideoContext_VideoProcessorSetOutputColorSpace(vctx, vp, *out_cs);
	ID3D11VideoContext_VideoProcessorSetStreamFrameFormat(vctx, vp, 0, .PROGRESSIVE);

	td := D3D11_TEXTURE2D_DESC.{Width = xx c.width, Height = xx c.height, MipLevels = 1, ArraySize = 1, Format = .NV12, SampleDesc = .{Count = 1}, Usage = .DEFAULT, BindFlags = .RENDER_TARGET};
	nv12: *ID3D11Texture2D;
	if FAILED(ID3D11Device_CreateTexture2D(dev, *td, null, *nv12)) return false;
	defer IUnknown_Release(nv12);
	td.Usage = .STAGING;
	td.BindFlags = 0;
	td.CPUAccessFlags = .READ;
	staging: *ID3D11Texture2D;
	if FAILED(ID3D11Device_CreateTexture2D(dev, *td, null, *staging)) return false;
	defer IUnknown_Release(staging);
	ovd := D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC.{ViewDimension = .TEXTURE2D};
	oview: *ID3D11VideoProcessorOutputView;
	if FAILED(ID3D11VideoDevice_CreateVideoProcessorOutputView(vdev, nv12, venum, *ovd, *oview)) return false;
	defer IUnknown_Release(oview);

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
			if info.LastPresentTime.QuadPart != 0 || !last.* {
				f := convert(c, ctx, vdev, vctx, venum, vp, oview, nv12, staging, res);
				if f { yuv.nv12_release(last.*); last.* = f; }
			}
			IUnknown_Release(res);
			IDXGIOutputDuplication_ReleaseFrame(dup);
		}
		// Static screens produce no new images; repeat the last so keyframe requests and late viewers get one.
		if last.* emit(c, last.*);
	}
	return true;
}

convert :: (c: *Capture, ctx: *ID3D11DeviceContext, vdev: *ID3D11VideoDevice, vctx: *ID3D11VideoContext, venum: *ID3D11VideoProcessorEnumerator,
	vp: *ID3D11VideoProcessor, oview: *ID3D11VideoProcessorOutputView, nv12: *ID3D11Texture2D, staging: *ID3D11Texture2D, res: *IDXGIResource) -> *yuv.Nv12 {
	tex: *ID3D11Texture2D;
	if FAILED(IUnknown_QueryInterface(res, *uid(ID3D11Texture2D_UUID), cast(**void) *tex)) return null;
	defer IUnknown_Release(tex);
	ivd := D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC.{ViewDimension = .TEXTURE2D};
	iview: *ID3D11VideoProcessorInputView;
	if FAILED(ID3D11VideoDevice_CreateVideoProcessorInputView(vdev, tex, venum, *ivd, *iview)) return null;
	stream := D3D11_VIDEO_PROCESSOR_STREAM.{Enable = 1, pInputSurface = iview};
	hr := ID3D11VideoContext_VideoProcessorBlt(vctx, vp, oview, 0, 1, *stream);
	IUnknown_Release(iview);
	if FAILED(hr) return null;
	ID3D11DeviceContext_CopyResource(ctx, staging, nv12);
	m: D3D11_MAPPED_SUBRESOURCE;
	if FAILED(ID3D11DeviceContext_Map(ctx, staging, 0, .READ, 0, *m)) return null;
	p := cast(*u8) m.pData;
	pitch := cast(int) m.RowPitch;
	f := yuv.nv12_from_planes(c.width, c.height, p, p + pitch * c.height, pitch);
	ID3D11DeviceContext_Unmap(ctx, staging, 0);
	return f;
}
