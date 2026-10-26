#+build windows
package gfx

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:mem"
import "fc:platform"
import "fc:prof"
import win "core:sys/windows"
import D3D11 "vendor:directx/d3d11"
import DXGI "vendor:directx/dxgi"
import D3D "vendor:directx/d3d_compiler"

// ISwapChain2 (not in vendor bindings): frame-latency waitable object.
@(private = "file")
ISwapChain2 :: struct #raw_union {
	#subtype isc1: DXGI.ISwapChain1,
	using vtable:  ^ISwapChain2_VTable,
}
@(private = "file")
ISwapChain2_VTable :: struct {
	using isc1_vtable:             DXGI.ISwapChain1_VTable,
	SetSourceSize:                 proc "system" (this: ^ISwapChain2, w, h: u32) -> DXGI.HRESULT,
	GetSourceSize:                 proc "system" (this: ^ISwapChain2, w, h: ^u32) -> DXGI.HRESULT,
	SetMaximumFrameLatency:        proc "system" (this: ^ISwapChain2, n: u32) -> DXGI.HRESULT,
	GetMaximumFrameLatency:        proc "system" (this: ^ISwapChain2, n: ^u32) -> DXGI.HRESULT,
	GetFrameLatencyWaitableObject: proc "system" (this: ^ISwapChain2) -> win.HANDLE,
}
@(private = "file")
ISwapChain2_UUID := &DXGI.IID{0xa8be2ac4, 0x199f, 0x4946, {0xb3, 0x31, 0x79, 0x59, 0x9f, 0xb9, 0x8d, 0xe7}}

@(private = "file")
D3D_Tex :: struct {
	tex: ^D3D11.ITexture2D,
	srv: ^D3D11.IShaderResourceView,
}

@(private = "file")
Dx :: struct {
	device:      ^D3D11.IDevice,
	ctx:         ^D3D11.IDeviceContext,
	swap:        ^DXGI.ISwapChain1,
	swap2:       ^ISwapChain2,
	rtv:         ^D3D11.IRenderTargetView,
	back_size:   [2]i32,
	offscreen:   ^D3D11.ITexture2D,
	vs:          ^D3D11.IVertexShader,
	ps:          ^D3D11.IPixelShader,
	blend:       ^D3D11.IBlendState,
	raster:      ^D3D11.IRasterizerState,
	sampler:     ^D3D11.ISamplerState,
	inst_buf:    ^D3D11.IBuffer,
	inst_srv:    ^D3D11.IShaderResourceView,
	inst_cap:    int,
	cbuf:        ^D3D11.IBuffer,
	swap_flags:  DXGI.SWAP_CHAIN,
	timers:      [GPU_TIMERS]Gpu_Timer,
	idle_query:  ^D3D11.IQuery,
}

// GPU time per frame from timestamp queries, read back GPU_TIMERS frames later so nothing waits.
@(private = "file")
GPU_TIMERS :: 6
@(private = "file")
Gpu_Timer :: struct {
	disjoint, t0, t1: ^D3D11.IQuery,
	frame:            u64,
	pending:          bool,
}

@(private = "file")
timer_read :: proc(t: ^Gpu_Timer) {
	if !t.pending do return
	dj: D3D11.QUERY_DATA_TIMESTAMP_DISJOINT
	a, b: u64
	flags := u32(transmute(D3D11.ASYNC_GETDATA_FLAGS)D3D11.ASYNC_GETDATA_FLAGS{.DONOTFLUSH})
	if dx.ctx->GetData(t.disjoint, &dj, size_of(dj), flags) != 0 do return // S_FALSE: not done yet
	t.pending = false
	if dj.Disjoint || dj.Frequency == 0 do return
	if dx.ctx->GetData(t.t0, &a, size_of(a), flags) != 0 || dx.ctx->GetData(t.t1, &b, size_of(b), flags) != 0 do return
	if t.frame >= g.stats.gpu_frame {
		g.stats.gpu_ns = i64(f64(b - a) * 1e9 / f64(dj.Frequency))
		g.stats.gpu_frame = t.frame
	}
}

@(private = "file")
dx: Dx

@(private = "file")
compile :: proc(entry, target: cstring) -> ^D3D11.IBlob {
	code, errs: ^D3D11.IBlob
	src := HLSL_SHADER_SRC
	hr := D3D.Compile(raw_data(src), uint(len(src)), "fc_shader", nil, nil, entry, target, 0, 0, &code, &errs)
	if hr < 0 {
		if errs != nil do fmt.eprintln("gfx: hlsl:", string(([^]u8)(errs->GetBufferPointer())[:errs->GetBufferSize()]))
		return nil
	}
	return code
}

@(private)
_backend_init :: proc() -> bool {
	levels := [1]D3D11.FEATURE_LEVEL{._11_0}
	hr := D3D11.CreateDevice(nil, .HARDWARE, nil, {.BGRA_SUPPORT}, &levels[0], 1, D3D11.SDK_VERSION, &dx.device, nil, &dx.ctx)
	if hr < 0 do return false

	vsb := compile("vs_main", "vs_5_0")
	psb := compile("ps_main", "ps_5_0")
	if vsb == nil || psb == nil do return false
	defer vsb->Release()
	defer psb->Release()
	dx.device->CreateVertexShader(vsb->GetBufferPointer(), vsb->GetBufferSize(), nil, &dx.vs)
	dx.device->CreatePixelShader(psb->GetBufferPointer(), psb->GetBufferSize(), nil, &dx.ps)

	bd: D3D11.BLEND_DESC
	bd.RenderTarget[0] = {
		BlendEnable           = true,
		SrcBlend              = .ONE,
		DestBlend             = .INV_SRC_ALPHA,
		BlendOp               = .ADD,
		SrcBlendAlpha         = .ONE,
		DestBlendAlpha        = .INV_SRC_ALPHA,
		BlendOpAlpha          = .ADD,
		RenderTargetWriteMask = u8(D3D11.COLOR_WRITE_ENABLE_ALL),
	}
	dx.device->CreateBlendState(&bd, &dx.blend)
	rd := D3D11.RASTERIZER_DESC{FillMode = .SOLID, CullMode = .NONE, ScissorEnable = true, DepthClipEnable = true}
	dx.device->CreateRasterizerState(&rd, &dx.raster)
	sd := D3D11.SAMPLER_DESC{Filter = .MIN_MAG_MIP_LINEAR, AddressU = .CLAMP, AddressV = .CLAMP, AddressW = .CLAMP, MaxLOD = 0}
	dx.device->CreateSamplerState(&sd, &dx.sampler)
	cbd := D3D11.BUFFER_DESC{ByteWidth = 16, Usage = .DYNAMIC, BindFlags = {.CONSTANT_BUFFER}, CPUAccessFlags = {.WRITE}}
	dx.device->CreateBuffer(&cbd, nil, &dx.cbuf)
	for &t in dx.timers {
		dx.device->CreateQuery(&{Query = .TIMESTAMP_DISJOINT}, &t.disjoint)
		dx.device->CreateQuery(&{Query = .TIMESTAMP}, &t.t0)
		dx.device->CreateQuery(&{Query = .TIMESTAMP}, &t.t1)
	}

	if !platform.is_headless() {
		hwnd := win.HWND(platform.native_window())
		dxgi_dev: ^DXGI.IDevice
		dx.device->QueryInterface(DXGI.IDevice_UUID, (^rawptr)(&dxgi_dev))
		adapter: ^DXGI.IAdapter
		dxgi_dev->GetAdapter(&adapter)
		factory: ^DXGI.IFactory2
		adapter->GetParent(DXGI.IFactory2_UUID, (^rawptr)(&factory))
		dx.swap_flags = {.FRAME_LATENCY_WAITABLE_OBJECT}
		desc := DXGI.SWAP_CHAIN_DESC1 {
			Format      = .B8G8R8A8_UNORM,
			SampleDesc  = {Count = 1},
			BufferUsage = {.RENDER_TARGET_OUTPUT},
			BufferCount = 2,
			Scaling     = .NONE,
			SwapEffect  = .FLIP_DISCARD,
			AlphaMode   = .IGNORE,
			Flags       = dx.swap_flags,
		}
		hr = factory->CreateSwapChainForHwnd(dx.device, hwnd, &desc, nil, nil, &dx.swap)
		factory->Release()
		adapter->Release()
		dxgi_dev->Release()
		if hr < 0 do return false
		if dx.swap->QueryInterface(ISwapChain2_UUID, (^rawptr)(&dx.swap2)) >= 0 {
			dx.swap2->SetMaximumFrameLatency(1) // lowest latency: CPU waits until the GPU can take a frame
			platform.set_frame_wait_handle(rawptr(dx.swap2->GetFrameLatencyWaitableObject()))
		}
	}
	return true
}

@(private)
_backend_native_device :: proc() -> rawptr {return rawptr(dx.device)}

@(private)
_backend_wait_idle :: proc() {
	if dx.ctx == nil do return
	if dx.idle_query == nil do dx.device->CreateQuery(&{Query = .EVENT}, &dx.idle_query)
	if dx.idle_query == nil {
		dx.ctx->Flush()
		return
	}
	dx.ctx->End(dx.idle_query)
	done: win.BOOL
	// The first call flushes the queued commands; S_OK means the GPU has finished all of them.
	for dx.ctx->GetData(dx.idle_query, &done, size_of(done), 0) != 0 {
		intrinsics.cpu_relax()
	}
}

@(private)
_backend_shutdown :: proc() {
	if dx.rtv != nil do dx.rtv->Release()
	if dx.swap2 != nil do dx.swap2->Release()
	if dx.swap != nil do dx.swap->Release()
	if dx.offscreen != nil do dx.offscreen->Release()
	if dx.inst_srv != nil do dx.inst_srv->Release()
	if dx.inst_buf != nil do dx.inst_buf->Release()
	dx.cbuf->Release()
	if dx.idle_query != nil do dx.idle_query->Release()
	for t in dx.timers {
		if t.disjoint != nil do t.disjoint->Release()
		if t.t0 != nil do t.t0->Release()
		if t.t1 != nil do t.t1->Release()
	}
	dx.sampler->Release()
	dx.raster->Release()
	dx.blend->Release()
	dx.ps->Release()
	dx.vs->Release()
	dx.ctx->Release()
	dx.device->Release()
	dx = {}
}

@(private = "file")
ensure_target :: proc(fb: [2]i32) -> bool {
	if dx.rtv != nil && dx.back_size == fb do return true
	if dx.rtv != nil {
		dx.rtv->Release()
		dx.rtv = nil
	}
	tex: ^D3D11.ITexture2D
	if dx.swap != nil {
		dx.ctx->OMSetRenderTargets(0, nil, nil)
		if dx.back_size != {} {
			if dx.swap->ResizeBuffers(0, u32(fb.x), u32(fb.y), .UNKNOWN, dx.swap_flags) < 0 do return false
		}
		dx.swap->GetBuffer(0, D3D11.ITexture2D_UUID, (^rawptr)(&tex))
	} else {
		if dx.offscreen != nil do dx.offscreen->Release()
		td := D3D11.TEXTURE2D_DESC {
			Width = u32(fb.x), Height = u32(fb.y), MipLevels = 1, ArraySize = 1,
			Format = .B8G8R8A8_UNORM, SampleDesc = {Count = 1}, Usage = .DEFAULT, BindFlags = {.RENDER_TARGET},
		}
		dx.device->CreateTexture2D(&td, nil, &dx.offscreen)
		tex = dx.offscreen
		tex->AddRef()
	}
	if tex == nil do return false
	dx.device->CreateRenderTargetView(tex, nil, &dx.rtv)
	tex->Release()
	dx.back_size = fb
	return true
}

@(private = "file")
ensure_instances :: proc(n: int) {
	if dx.inst_cap >= n && dx.inst_buf != nil do return
	if dx.inst_srv != nil do dx.inst_srv->Release()
	if dx.inst_buf != nil do dx.inst_buf->Release()
	dx.inst_cap = max(n, dx.inst_cap * 2, 4096)
	bd := D3D11.BUFFER_DESC {
		ByteWidth           = u32(dx.inst_cap * size_of(Instance)),
		Usage               = .DYNAMIC,
		BindFlags           = {.SHADER_RESOURCE},
		CPUAccessFlags      = {.WRITE},
		MiscFlags           = {.BUFFER_STRUCTURED},
		StructureByteStride = size_of(Instance),
	}
	dx.device->CreateBuffer(&bd, nil, &dx.inst_buf)
	srvd := D3D11.SHADER_RESOURCE_VIEW_DESC{Format = .UNKNOWN, ViewDimension = .BUFFER}
	srvd.Buffer.NumElements = u32(dx.inst_cap)
	dx.device->CreateShaderResourceView(dx.inst_buf, &srvd, &dx.inst_srv)
}

@(private)
_backend_submit :: proc(insts: []Instance, batches: []Batch, clear: Color, fb: [2]i32) {
	if fb.x <= 0 || fb.y <= 0 do return
	if !ensure_target(fb) do return
	for &t in dx.timers do timer_read(&t)
	timer := &dx.timers[g.frame_index % GPU_TIMERS]
	timer_read(timer)
	if !timer.pending && timer.disjoint != nil && timer.t0 != nil && timer.t1 != nil {
		dx.ctx->Begin(timer.disjoint)
		dx.ctx->End(timer.t0)
	} else {
		timer = nil // still in flight from GPU_TIMERS frames ago: skip timing this frame
	}
	ensure_instances(len(insts))
	if len(insts) > 0 {
		// WRITE_DISCARD: the driver renames the buffer (ring-buffered under the hood).
		mapped: D3D11.MAPPED_SUBRESOURCE
		if dx.ctx->Map(dx.inst_buf, 0, .WRITE_DISCARD, {}, &mapped) >= 0 {
			mem.copy_non_overlapping(mapped.pData, raw_data(insts), len(insts) * size_of(Instance))
			dx.ctx->Unmap(dx.inst_buf, 0)
		}
	}
	cc := premul(clear)
	cc4 := [4]f32{cc.r, cc.g, cc.b, cc.a}
	dx.ctx->ClearRenderTargetView(dx.rtv, &cc4)
	vp := D3D11.VIEWPORT{Width = f32(fb.x), Height = f32(fb.y), MaxDepth = 1}
	dx.ctx->RSSetViewports(1, &vp)
	dx.ctx->RSSetState(dx.raster)
	dx.ctx->OMSetRenderTargets(1, &dx.rtv, nil)
	dx.ctx->OMSetBlendState(dx.blend, nil, 0xffffffff)
	dx.ctx->IASetPrimitiveTopology(.TRIANGLESTRIP)
	dx.ctx->VSSetShader(dx.vs, nil, 0)
	dx.ctx->PSSetShader(dx.ps, nil, 0)
	dx.ctx->VSSetShaderResources(1, 1, &dx.inst_srv)
	dx.ctx->VSSetConstantBuffers(0, 1, &dx.cbuf)
	dx.ctx->PSSetSamplers(0, 1, &dx.sampler)

	sr := D3D11.RECT{0, 0, fb.x, fb.y}
	dx.ctx->RSSetScissorRects(1, &sr)

	Uniforms :: struct {viewport: [2]f32, base: u32, pad: u32}
	zb := prof.zone_begin("gfx.batches")
	white := (^D3D_Tex)(g.textures[g.white].native).srv
	for b in batches {
		mapped: D3D11.MAPPED_SUBRESOURCE
		if dx.ctx->Map(dx.cbuf, 0, .WRITE_DISCARD, {}, &mapped) >= 0 {
			(^Uniforms)(mapped.pData)^ = {viewport = {f32(fb.x), f32(fb.y)}, base = b.first}
			dx.ctx->Unmap(dx.cbuf, 0)
		}
		srvs: [TEX_SLOTS]^D3D11.IShaderResourceView
		for i in 0 ..< TEX_SLOTS {
			srvs[i] = white
			if u32(i) < b.n_slots do srvs[i] = (^D3D_Tex)(g.textures[b.slots[i]].native).srv
		}
		dx.ctx->PSSetShaderResources(3, u32(max(b.n_slots, 1)), &srvs[0])
		t2 := b.tex2 != 0 ? b.tex2 : g.white
		dt2 := (^D3D_Tex)(g.textures[t2].native)
		dx.ctx->PSSetShaderResources(2, 1, &dt2.srv)
		dx.ctx->DrawInstanced(4, b.count, 0, 0)
	}
	prof.zone_end(zb)
	if timer != nil {
		dx.ctx->End(timer.t1)
		dx.ctx->End(timer.disjoint)
		timer.frame = g.frame_index
		timer.pending = true
	}
	prof.zone("gfx.present")
	if dx.swap != nil {
		dx.swap->Present(1, {})
	} else {
		dx.ctx->Flush()
	}
}

@(private)
_backend_texture_create :: proc(w, h: i32, format: Texture_Format, pixels: []u8) -> rawptr {
	td := D3D11.TEXTURE2D_DESC {
		Width = u32(w), Height = u32(h), MipLevels = 1, ArraySize = 1,
		Format = format == .R8 ? .R8_UNORM : (format == .RG8 ? .R8G8_UNORM : .R8G8B8A8_UNORM),
		SampleDesc = {Count = 1}, Usage = .DEFAULT, BindFlags = {.SHADER_RESOURCE},
	}
	dt := new(D3D_Tex)
	init: D3D11.SUBRESOURCE_DATA
	pinit: ^D3D11.SUBRESOURCE_DATA
	if len(pixels) > 0 {
		init = {pSysMem = raw_data(pixels), SysMemPitch = u32(w) * u32(format_bpp(format))}
		pinit = &init
	}
	if dx.device->CreateTexture2D(&td, pinit, &dt.tex) < 0 {
		free(dt)
		return nil
	}
	dx.device->CreateShaderResourceView(dt.tex, nil, &dt.srv)
	return dt
}

@(private)
_backend_texture_update :: proc(native: rawptr, format: Texture_Format, x, y, w, h: i32, pixels: []u8, stride: i32) {
	dt := (^D3D_Tex)(native)
	box := D3D11.BOX{left = u32(x), top = u32(y), front = 0, right = u32(x + w), bottom = u32(y + h), back = 1}
	dx.ctx->UpdateSubresource(dt.tex, 0, &box, raw_data(pixels), u32(stride), 0)
}

@(private)
_backend_texture_destroy :: proc(native: rawptr) {
	dt := (^D3D_Tex)(native)
	if dt == nil do return
	dt.srv->Release()
	dt.tex->Release()
	free(dt)
}

@(private)
_backend_read_pixels :: proc(allocator: runtime.Allocator) -> ([]u8, int, int) {
	if dx.offscreen == nil do return nil, 0, 0
	w, h := int(dx.back_size.x), int(dx.back_size.y)
	td := D3D11.TEXTURE2D_DESC {
		Width = u32(w), Height = u32(h), MipLevels = 1, ArraySize = 1,
		Format = .B8G8R8A8_UNORM, SampleDesc = {Count = 1}, Usage = .STAGING, CPUAccessFlags = {.READ},
	}
	staging: ^D3D11.ITexture2D
	if dx.device->CreateTexture2D(&td, nil, &staging) < 0 do return nil, 0, 0
	defer staging->Release()
	dx.ctx->CopyResource(staging, dx.offscreen)
	mapped: D3D11.MAPPED_SUBRESOURCE
	if dx.ctx->Map(staging, 0, .READ, {}, &mapped) < 0 do return nil, 0, 0
	defer dx.ctx->Unmap(staging, 0)
	out := make([]u8, w * h * 4, allocator)
	for yy in 0 ..< h {
		row := ([^]u8)(uintptr(mapped.pData) + uintptr(yy * int(mapped.RowPitch)))
		for xx in 0 ..< w {
			i := xx * 4
			o := (yy * w + xx) * 4
			out[o + 0] = row[i + 2]
			out[o + 1] = row[i + 1]
			out[o + 2] = row[i + 0]
			out[o + 3] = row[i + 3]
		}
	}
	return out, w, h
}
