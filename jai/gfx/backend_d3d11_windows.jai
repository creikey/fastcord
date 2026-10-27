#scope_file

// ISwapChain2 (not in vendor bindings): frame-latency waitable object.
ISwapChain2 :: union {
	#subtype isc1: DXGI.ISwapChain1;
	using vtable: *ISwapChain2_VTable;
}
ISwapChain2_VTable :: struct {
	using isc1_vtable: DXGI.ISwapChain1_VTable;
	SetSourceSize: (this: *ISwapChain2, w: u32, h: u32) -> DXGI.HRESULT #c_call;
	GetSourceSize: (this: *ISwapChain2, w: *u32, h: *u32) -> DXGI.HRESULT #c_call;
	SetMaximumFrameLatency: (this: *ISwapChain2, n: u32) -> DXGI.HRESULT #c_call;
	GetMaximumFrameLatency: (this: *ISwapChain2, n: *u32) -> DXGI.HRESULT #c_call;
	GetFrameLatencyWaitableObject: (this: *ISwapChain2) -> win.HANDLE #c_call;
}
ISwapChain2_UUID := *DXGI.IID.{0xa8be2ac4, 0x199f, 0x4946, .{0xb3, 0x31, 0x79, 0x59, 0x9f, 0xb9, 0x8d, 0xe7}};

D3D_Tex :: struct {
	tex: *D3D11.ITexture2D;
	srv: *D3D11.IShaderResourceView;
}

Dx :: struct {
	device: *D3D11.IDevice;
	ctx: *D3D11.IDeviceContext;
	swap: *DXGI.ISwapChain1;
	swap2: *ISwapChain2;
	rtv: *D3D11.IRenderTargetView;
	back_size: [2]s32;
	offscreen: *D3D11.ITexture2D;
	vs: *D3D11.IVertexShader;
	ps: *D3D11.IPixelShader;
	blend: *D3D11.IBlendState;
	raster: *D3D11.IRasterizerState;
	sampler: *D3D11.ISamplerState;
	inst_buf: *D3D11.IBuffer;
	inst_srv: *D3D11.IShaderResourceView;
	inst_cap: int;
	cbuf: *D3D11.IBuffer;
	swap_flags: DXGI.SWAP_CHAIN;
	timers: [GPU_TIMERS]Gpu_Timer;
	idle_query: *D3D11.IQuery;
}

// GPU time per frame from timestamp queries, read back GPU_TIMERS frames later so nothing waits.
// GPU time per frame from timestamp queries, read back GPU_TIMERS frames later so nothing waits.
GPU_TIMERS :: 6;
Gpu_Timer :: struct {
	disjoint, t0, t1: *D3D11.IQuery;
	frame: u64;
	pending: bool;
}

timer_read :: (t: *Gpu_Timer) {
	if !t.pending { return; }
	dj: D3D11.QUERY_DATA_TIMESTAMP_DISJOINT;
	a, b: u64;
	flags := cast(u32)(transmute(D3D11.ASYNC_GETDATA_FLAGS, D3D11.ASYNC_GETDATA_FLAGS).{.DONOTFLUSH});
	if dx.ctx->GetData(t.disjoint, *dj, size_of(dj), flags) != 0 { return; } // S_FALSE: not done yet
	t.pending = false;
	if dj.Disjoint || dj.Frequency == 0 { return; }
	if dx.ctx->GetData(t.t0, *a, size_of(a), flags) != 0 || dx.ctx->GetData(t.t1, *b, size_of(b), flags) != 0 { return; }
	if t.frame >= g.stats.gpu_frame {
		g.stats.gpu_ns = cast(s64)(cast(float64)(b - a) * 1000000000 / cast(float64)(dj.Frequency));
		g.stats.gpu_frame = t.frame;
	}
}

dx: Dx;

compile :: (entry: *u8, target: *u8) -> *D3D11.IBlob {
	code, errs: *D3D11.IBlob;
	src := HLSL_SHADER_SRC;
	hr := D3D.Compile(raw_data(src), cast(u64)(len(src)), "fc_shader", null, null, entry, target, 0, 0, *code, *errs);
	if hr < 0 {
		if errs != null { fmt.eprintln("gfx: hlsl:", as_string(sub(cast(*u8)(errs->GetBufferPointer()), 0, errs->GetBufferSize()))); }
		return null;
	}
	return code;
}
#scope_module

_backend_init :: () -> bool {
	levels := D3D11.FEATURE_LEVEL.[._11_0];
	hr := D3D11.CreateDevice(null, .HARDWARE, null, .{.BGRA_SUPPORT}, *levels[0], 1, D3D11.SDK_VERSION, *dx.device, null, *dx.ctx);
	if hr < 0 { return false; }

	vsb := compile("vs_main", "vs_5_0");
	psb := compile("ps_main", "ps_5_0");
	if vsb == null || psb == null { return false; }
	defer vsb->Release();
	defer psb->Release();
	dx.device->CreateVertexShader(vsb->GetBufferPointer(), vsb->GetBufferSize(), null, *dx.vs);
	dx.device->CreatePixelShader(psb->GetBufferPointer(), psb->GetBufferSize(), null, *dx.ps);

	bd: D3D11.BLEND_DESC;
	bd.RenderTarget[0] = .{
		BlendEnable = true,
		SrcBlend = .ONE,
		DestBlend = .INV_SRC_ALPHA,
		BlendOp = .ADD,
		SrcBlendAlpha = .ONE,
		DestBlendAlpha = .INV_SRC_ALPHA,
		BlendOpAlpha = .ADD,
		RenderTargetWriteMask = cast(u8)(D3D11.COLOR_WRITE_ENABLE_ALL)
	};
	dx.device->CreateBlendState(*bd, *dx.blend);
	rd := D3D11.RASTERIZER_DESC.{FillMode = .SOLID, CullMode = .NONE, ScissorEnable = true, DepthClipEnable = true};
	dx.device->CreateRasterizerState(*rd, *dx.raster);
	sd := D3D11.SAMPLER_DESC.{Filter = .MIN_MAG_MIP_LINEAR, AddressU = .CLAMP, AddressV = .CLAMP, AddressW = .CLAMP, MaxLOD = 0};
	dx.device->CreateSamplerState(*sd, *dx.sampler);
	cbd := D3D11.BUFFER_DESC.{ByteWidth = 16, Usage = .DYNAMIC, BindFlags = .{.CONSTANT_BUFFER}, CPUAccessFlags = .{.WRITE}};
	dx.device->CreateBuffer(*cbd, null, *dx.cbuf);
	for * t: dx.timers {
		dx.device->CreateQuery(*.{Query = .TIMESTAMP_DISJOINT}, *t.disjoint);
		dx.device->CreateQuery(*.{Query = .TIMESTAMP}, *t.t0);
		dx.device->CreateQuery(*.{Query = .TIMESTAMP}, *t.t1);
	}

	if !platform.is_headless() {
		hwnd := win.HWND(platform.native_window());
		dxgi_dev: *DXGI.IDevice;
		dx.device->QueryInterface(DXGI.IDevice_UUID, cast(**void)(*dxgi_dev));
		adapter: *DXGI.IAdapter;
		dxgi_dev->GetAdapter(*adapter);
		factory: *DXGI.IFactory2;
		adapter->GetParent(DXGI.IFactory2_UUID, cast(**void)(*factory));
		dx.swap_flags = .{.FRAME_LATENCY_WAITABLE_OBJECT};
		desc := DXGI.SWAP_CHAIN_DESC1.{
			Format = .B8G8R8A8_UNORM,
			SampleDesc = .{Count = 1},
			BufferUsage = .{.RENDER_TARGET_OUTPUT},
			BufferCount = 2,
			Scaling = .NONE,
			SwapEffect = .FLIP_DISCARD,
			AlphaMode = .IGNORE,
			Flags = dx.swap_flags
		};
		hr = factory->CreateSwapChainForHwnd(dx.device, hwnd, *desc, null, null, *dx.swap);
		factory->Release();
		adapter->Release();
		dxgi_dev->Release();
		if hr < 0 { return false; }
		if dx.swap->QueryInterface(ISwapChain2_UUID, cast(**void)(*dx.swap2)) >= 0 {
			dx.swap2->SetMaximumFrameLatency(1); // lowest latency: CPU waits until the GPU can take a frame
			platform.set_frame_wait_handle(cast(*void)(dx.swap2->GetFrameLatencyWaitableObject()));
		}
	}
	return true;
}

_backend_native_device :: () -> *void {return cast(*void)(dx.device);}

_backend_wait_idle :: () {
	if dx.ctx == null { return; }
	if dx.idle_query == null { dx.device->CreateQuery(*.{Query = .EVENT}, *dx.idle_query); }
	if dx.idle_query == null {
		dx.ctx->Flush();
		return;
	}
	dx.ctx->End(dx.idle_query);
	done: win.BOOL;
	// The first call flushes the queued commands; S_OK means the GPU has finished all of them.
	while dx.ctx->GetData(dx.idle_query, *done, size_of(done), 0) != 0 {
		intrinsics.cpu_relax();
	}
}

_backend_shutdown :: () {
	if dx.rtv != null { dx.rtv->Release(); }
	if dx.swap2 != null { dx.swap2->Release(); }
	if dx.swap != null { dx.swap->Release(); }
	if dx.offscreen != null { dx.offscreen->Release(); }
	if dx.inst_srv != null { dx.inst_srv->Release(); }
	if dx.inst_buf != null { dx.inst_buf->Release(); }
	dx.cbuf->Release();
	if dx.idle_query != null { dx.idle_query->Release(); }
	for t: dx.timers {
		if t.disjoint != null { t.disjoint->Release(); }
		if t.t0 != null { t.t0->Release(); }
		if t.t1 != null { t.t1->Release(); }
	}
	dx.sampler->Release();
	dx.raster->Release();
	dx.blend->Release();
	dx.ps->Release();
	dx.vs->Release();
	dx.ctx->Release();
	dx.device->Release();
	dx = .{};
}
#scope_file

ensure_target :: (fb: [2]s32) -> bool {
	if dx.rtv != null && dx.back_size == fb { return true; }
	if dx.rtv != null {
		dx.rtv->Release();
		dx.rtv = null;
	}
	tex: *D3D11.ITexture2D;
	if dx.swap != null {
		dx.ctx->OMSetRenderTargets(0, null, null);
		if dx.back_size != .{} {
			if dx.swap->ResizeBuffers(0, cast(u32)(fb.x), cast(u32)(fb.y), .UNKNOWN, dx.swap_flags) < 0 { return false; }
		}
		dx.swap->GetBuffer(0, D3D11.ITexture2D_UUID, cast(**void)(*tex));
	} else {
		if dx.offscreen != null { dx.offscreen->Release(); }
		td := D3D11.TEXTURE2D_DESC.{
			Width = cast(u32)(fb.x), Height = cast(u32)(fb.y), MipLevels = 1, ArraySize = 1,
			Format = .B8G8R8A8_UNORM, SampleDesc = .{Count = 1}, Usage = .DEFAULT, BindFlags = .{.RENDER_TARGET}
		};
		dx.device->CreateTexture2D(*td, null, *dx.offscreen);
		tex = dx.offscreen;
		tex->AddRef();
	}
	if tex == null { return false; }
	dx.device->CreateRenderTargetView(tex, null, *dx.rtv);
	tex->Release();
	dx.back_size = fb;
	return true;
}

ensure_instances :: (n: int) {
	if dx.inst_cap >= n && dx.inst_buf != null { return; }
	if dx.inst_srv != null { dx.inst_srv->Release(); }
	if dx.inst_buf != null { dx.inst_buf->Release(); }
	dx.inst_cap = max(n, dx.inst_cap * 2, 4096);
	bd := D3D11.BUFFER_DESC.{
		ByteWidth = cast(u32)(dx.inst_cap * size_of(Instance)),
		Usage = .DYNAMIC,
		BindFlags = .{.SHADER_RESOURCE},
		CPUAccessFlags = .{.WRITE},
		MiscFlags = .{.BUFFER_STRUCTURED},
		StructureByteStride = size_of(Instance)
	};
	dx.device->CreateBuffer(*bd, null, *dx.inst_buf);
	srvd := D3D11.SHADER_RESOURCE_VIEW_DESC.{Format = .UNKNOWN, ViewDimension = .BUFFER};
	srvd.Buffer.NumElements = cast(u32)(dx.inst_cap);
	dx.device->CreateShaderResourceView(dx.inst_buf, *srvd, *dx.inst_srv);
}
#scope_module

_backend_submit :: (insts: []Instance, batches: []Batch, clear: Color, fb: [2]s32) {
	if fb.x <= 0 || fb.y <= 0 { return; }
	if !ensure_target(fb) { return; }
	for * t: dx.timers { timer_read(*t); }
	timer := *dx.timers[g.frame_index % GPU_TIMERS];
	timer_read(timer);
	if !timer.pending && timer.disjoint != null && timer.t0 != null && timer.t1 != null {
		dx.ctx->Begin(timer.disjoint);
		dx.ctx->End(timer.t0);
	} else {
		timer = null; // still in flight from GPU_TIMERS frames ago: skip timing this frame
	}
	ensure_instances(len(insts));
	if len(insts) > 0 {
		// WRITE_DISCARD: the driver renames the buffer (ring-buffered under the hood).
		mapped: D3D11.MAPPED_SUBRESOURCE;
		if dx.ctx->cast(Map)(dx.inst_buf, 0, .WRITE_DISCARD, .{}, *mapped) >= 0 {
			mem.copy_non_overlapping(mapped.pData, raw_data(insts), len(insts) * size_of(Instance));
			dx.ctx->Unmap(dx.inst_buf, 0);
		}
	}
	cc := premul(clear);
	cc4 := float32.[cc.r, cc.g, cc.b, cc.a];
	dx.ctx->ClearRenderTargetView(dx.rtv, *cc4);
	vp := D3D11.VIEWPORT.{Width = cast(float32)(fb.x), Height = cast(float32)(fb.y), MaxDepth = 1};
	dx.ctx->RSSetViewports(1, *vp);
	dx.ctx->RSSetState(dx.raster);
	dx.ctx->OMSetRenderTargets(1, *dx.rtv, null);
	dx.ctx->OMSetBlendState(dx.blend, null, 0xffffffff);
	dx.ctx->IASetPrimitiveTopology(.TRIANGLESTRIP);
	dx.ctx->VSSetShader(dx.vs, null, 0);
	dx.ctx->PSSetShader(dx.ps, null, 0);
	dx.ctx->VSSetShaderResources(1, 1, *dx.inst_srv);
	dx.ctx->VSSetConstantBuffers(0, 1, *dx.cbuf);
	dx.ctx->PSSetSamplers(0, 1, *dx.sampler);

	sr := D3D11.RECT.{0, 0, fb.x, fb.y};
	dx.ctx->RSSetScissorRects(1, *sr);

	Uniforms :: struct {viewport: [2]float32; base: u32; pad: u32;}
	zb := prof.zone_begin("gfx.batches");
	white := cast(*D3D_Tex)(g.textures[g.white].native).srv;
	for b: batches {
		mapped: D3D11.MAPPED_SUBRESOURCE;
		if dx.ctx->cast(Map)(dx.cbuf, 0, .WRITE_DISCARD, .{}, *mapped) >= 0 {
			(cast(*Uniforms)(mapped.pData)).* = .{viewport = .{cast(float32)(fb.x), cast(float32)(fb.y)}, base = b.first};
			dx.ctx->Unmap(dx.cbuf, 0);
		}
		srvs: [TEX_SLOTS]*D3D11.IShaderResourceView;
		for i: 0..TEX_SLOTS-1 {
			srvs[i] = white;
			if cast(u32)(i) < b.n_slots { srvs[i] = cast(*D3D_Tex)(g.textures[b.slots[i]].native).srv; }
		}
		dx.ctx->PSSetShaderResources(3, cast(u32)(max(b.n_slots, 1)), *srvs[0]);
		t2 := ifx b.tex2 != 0 then b.tex2 else g.white;
		dt2 := cast(*D3D_Tex)(g.textures[t2].native);
		dx.ctx->PSSetShaderResources(2, 1, *dt2.srv);
		dx.ctx->DrawInstanced(4, b.count, 0, 0);
	}
	prof.zone_end(zb);
	if timer != null {
		dx.ctx->End(timer.t1);
		dx.ctx->End(timer.disjoint);
		timer.frame = g.frame_index;
		timer.pending = true;
	}
	prof.zone("gfx.present");
	if dx.swap != null {
		{ hr := dx.swap->Present(1, .{});
		if hr < 0 {
			g.diag.present_fails += 1;
			note_failure(cast(s32)(hr));
		} }
	} else {
		dx.ctx->Flush();
	}
}
#scope_file

note_failure :: (hr: s32) {
	g.diag.last_hresult = hr;
	g.diag.device_removed = cast(s32)(dx.device->GetDeviceRemovedReason());
}
#scope_module

_backend_texture_create :: (w: s32, h: s32, format: Texture_Format, pixels: []u8) -> *void {
	td := D3D11.TEXTURE2D_DESC.{
		Width = cast(u32)(w), Height = cast(u32)(h), MipLevels = 1, ArraySize = 1,
		Format = ifx format == .R8 then .R8_UNORM else (ifx format == .RG8 then .R8G8_UNORM else .R8G8B8A8_UNORM),
		SampleDesc = .{Count = 1}, Usage = .DEFAULT, BindFlags = .{.SHADER_RESOURCE}
	};
	dt := new(D3D_Tex);
	init: D3D11.SUBRESOURCE_DATA;
	pinit: *D3D11.SUBRESOURCE_DATA;
	if len(pixels) > 0 {
		init = .{pSysMem = raw_data(pixels), SysMemPitch = cast(u32)(w) * cast(u32)(format_bpp(format))};
		pinit = *init;
	}
	{ hr := dx.device->CreateTexture2D(*td, pinit, *dt.tex);
	if hr < 0 {
		note_failure(cast(s32)(hr));
		free(dt);
		return null;
	} }
	{ hr := dx.device->CreateShaderResourceView(dt.tex, null, *dt.srv);
	if hr < 0 {
		note_failure(cast(s32)(hr));
		dt.tex->Release();
		free(dt);
		return null;
	} }
	return dt;
}

_backend_texture_update :: (native: *void, format: Texture_Format, x: s32, y: s32, w: s32, h: s32, pixels: []u8, stride: s32) {
	dt := cast(*D3D_Tex)(native);
	box := D3D11.BOX.{left = cast(u32)(x), top = cast(u32)(y), front = 0, right = cast(u32)(x + w), bottom = cast(u32)(y + h), back = 1};
	dx.ctx->UpdateSubresource(dt.tex, 0, *box, raw_data(pixels), cast(u32)(stride), 0);
}

_backend_texture_destroy :: (native: *void) {
	dt := cast(*D3D_Tex)(native);
	if dt == null { return; }
	dt.srv->Release();
	dt.tex->Release();
	free(dt);
}

_backend_read_pixels :: (allocator: Allocator) -> []u8, int, int {
	if dx.offscreen == null { return .{}, 0, 0; }
	w, h := cast(int)(dx.back_size.x), cast(int)(dx.back_size.y);
	td := D3D11.TEXTURE2D_DESC.{
		Width = cast(u32)(w), Height = cast(u32)(h), MipLevels = 1, ArraySize = 1,
		Format = .B8G8R8A8_UNORM, SampleDesc = .{Count = 1}, Usage = .STAGING, CPUAccessFlags = .{.READ}
	};
	staging: *D3D11.ITexture2D;
	if dx.device->CreateTexture2D(*td, null, *staging) < 0 { return .{}, 0, 0; }
	defer staging->Release();
	dx.ctx->CopyResource(staging, dx.offscreen);
	mapped: D3D11.MAPPED_SUBRESOURCE;
	if dx.ctx->cast(Map)(staging, 0, .READ, .{}, *mapped) < 0 { return .{}, 0, 0; }
	defer dx.ctx->Unmap(staging, 0);
	out := make_slice(u8, w * h * 4, allocator);
	for yy: 0..h-1 {
		row := cast(*u8)(cast(u64)(mapped.pData) + cast(u64)(yy * cast(int)(mapped.RowPitch)));
		for xx_: 0..w-1 {
			i := xx_ * 4;
			o := (yy * w + xx_) * 4;
			at(*out, o + 0).* = row[i + 2];
			at(*out, o + 1).* = row[i + 1];
			at(*out, o + 2).* = row[i + 0];
			at(*out, o + 3).* = row[i + 3];
		}
	}
	return out, w, h;
}
#scope_export

