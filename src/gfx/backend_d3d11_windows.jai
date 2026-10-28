#scope_module

backend_init :: () -> bool {
    levels := D3D_FEATURE_LEVEL.[._11_0];
    hr := D3D11CreateDevice(null, .HARDWARE, null, .BGRA_SUPPORT, levels.data, 1, D3D11_SDK_VERSION, *dx.device, null, *dx.ctx);
    if FAILED(hr) return false;

    vsb := compile("vs_main", "vs_5_0");
    psb := compile("ps_main", "ps_5_0");
    defer { free(vsb); free(psb); }
    if !vsb || !psb return false;
    ID3D11Device_CreateVertexShader(dx.device, vsb.data, xx vsb.count, null, *dx.vs);
    ID3D11Device_CreatePixelShader(dx.device, psb.data, xx psb.count, null, *dx.ps);

    bd: D3D11_BLEND_DESC;
    bd.RenderTarget[0] = .{
        BlendEnable = 1,
        SrcBlend = .ONE,
        DestBlend = .INV_SRC_ALPHA,
        BlendOp = .ADD,
        SrcBlendAlpha = .ONE,
        DestBlendAlpha = .INV_SRC_ALPHA,
        BlendOpAlpha = .ADD,
        RenderTargetWriteMask = cast(u8) D3D11_COLOR_WRITE_ENABLE.ALL,
    };
    ID3D11Device_CreateBlendState(dx.device, *bd, *dx.blend);
    rd := D3D11_RASTERIZER_DESC.{FillMode = .SOLID, CullMode = .NONE, ScissorEnable = 1, DepthClipEnable = 1};
    ID3D11Device_CreateRasterizerState(dx.device, *rd, *dx.raster);
    sd := D3D11_SAMPLER_DESC.{Filter = .MIN_MAG_MIP_LINEAR, AddressU = .CLAMP, AddressV = .CLAMP, AddressW = .CLAMP, MaxLOD = 0};
    ID3D11Device_CreateSamplerState(dx.device, *sd, *dx.sampler);
    cbd := D3D11_BUFFER_DESC.{ByteWidth = 16, Usage = .DYNAMIC, BindFlags = .CONSTANT_BUFFER, CPUAccessFlags = .WRITE};
    ID3D11Device_CreateBuffer(dx.device, *cbd, null, *dx.cbuf);
    qdj := D3D11_QUERY_DESC.{Query = .TIMESTAMP_DISJOINT};
    qts := D3D11_QUERY_DESC.{Query = .TIMESTAMP};
    for * dx.timers {
        ID3D11Device_CreateQuery(dx.device, *qdj, *it.disjoint);
        ID3D11Device_CreateQuery(dx.device, *qts, *it.t0);
        ID3D11Device_CreateQuery(dx.device, *qts, *it.t1);
    }

    if !platform.is_headless() {
        dxgi_dev: *IDXGIDevice;
        IUnknown_QueryInterface(dx.device, *uid(IDXGIDevice_UUID), cast(**void) *dxgi_dev);
        adapter: *IDXGIAdapter;
        IDXGIDevice_GetAdapter(dxgi_dev, *adapter);
        factory: *IDXGIFactory2;
        IDXGIObject_GetParent(adapter, *uid(IDXGIFactory2_UUID), cast(**void) *factory);
        dx.swap_flags = .FRAME_LATENCY_WAITABLE_OBJECT;
        desc := DXGI_SWAP_CHAIN_DESC1.{
            Format = .B8G8R8A8_UNORM,
            SampleDesc = .{Count = 1},
            BufferUsage = .RENDER_TARGET_OUTPUT,
            BufferCount = 2,
            Scaling = .STRETCH,
            SwapEffect = .FLIP_DISCARD,
            AlphaMode = .IGNORE,
            Flags = xx dx.swap_flags,
        };
        hr = IDXGIFactory2_CreateSwapChainForHwnd(factory, dx.device, platform.native_window(), *desc, null, null, *dx.swap);
        IUnknown_Release(factory);
        IUnknown_Release(adapter);
        IUnknown_Release(dxgi_dev);
        if FAILED(hr) return false;
        if SUCCEEDED(IUnknown_QueryInterface(dx.swap, *uid(IDXGISwapChain2_UUID), cast(**void) *dx.swap2)) {
            IDXGISwapChain2_SetMaximumFrameLatency(dx.swap2, 1); // lowest latency: CPU waits until the GPU can take a frame
            platform.set_frame_wait_handle(IDXGISwapChain2_GetFrameLatencyWaitableObject(dx.swap2));
        }
    }
    return true;
}

backend_native_device :: () -> *void { return dx.device; }

backend_wait_idle :: () {
    if dx.ctx == null return;
    if dx.idle_query == null {
        qe := D3D11_QUERY_DESC.{Query = .EVENT};
        ID3D11Device_CreateQuery(dx.device, *qe, *dx.idle_query);
    }
    if dx.idle_query == null {
        ID3D11DeviceContext_Flush(dx.ctx);
        return;
    }
    ID3D11DeviceContext_End(dx.ctx, dx.idle_query);
    done: BOOL;
    // The first call flushes the queued commands; S_OK means the GPU has finished all of them.
    while ID3D11DeviceContext_GetData(dx.ctx, dx.idle_query, *done, size_of(BOOL), 0) != S_OK {
        #asm { pause; }
    }
}

backend_shutdown :: () {
    safe_release(dx.rtv);
    safe_release(dx.swap2);
    safe_release(dx.swap);
    safe_release(dx.offscreen);
    safe_release(dx.inst_srv);
    safe_release(dx.inst_buf);
    safe_release(dx.cbuf);
    safe_release(dx.idle_query);
    for dx.timers {
        safe_release(it.disjoint);
        safe_release(it.t0);
        safe_release(it.t1);
    }
    safe_release(dx.sampler);
    safe_release(dx.raster);
    safe_release(dx.blend);
    safe_release(dx.ps);
    safe_release(dx.vs);
    safe_release(dx.ctx);
    safe_release(dx.device);
    dx = .{};
}

backend_submit :: (insts: []Instance, batches: []Batch, clear: Color, fb: [2]s32) {
    if fb[0] <= 0 || fb[1] <= 0 return;
    if !ensure_target(fb) return;
    for * dx.timers timer_read(it);
    timer := *dx.timers[g.frame_index % GPU_TIMERS];
    timer_read(timer);
    if !timer.pending && timer.disjoint && timer.t0 && timer.t1 {
        ID3D11DeviceContext_Begin(dx.ctx, timer.disjoint);
        ID3D11DeviceContext_End(dx.ctx, timer.t0);
    } else {
        timer = null; // still in flight from GPU_TIMERS frames ago: skip timing this frame
    }
    ensure_instances(insts.count);
    if insts {
        // WRITE_DISCARD: the driver renames the buffer (ring-buffered under the hood).
        mapped: D3D11_MAPPED_SUBRESOURCE;
        if SUCCEEDED(ID3D11DeviceContext_Map(dx.ctx, dx.inst_buf, 0, .WRITE_DISCARD, 0, *mapped)) {
            memcpy(mapped.pData, insts.data, insts.count * size_of(Instance));
            ID3D11DeviceContext_Unmap(dx.ctx, dx.inst_buf, 0);
        }
    }
    cc := premul(clear);
    ID3D11DeviceContext_ClearRenderTargetView(dx.ctx, dx.rtv, *cc);
    vp := D3D11_VIEWPORT.{Width = cast(float32) fb[0], Height = cast(float32) fb[1], MaxDepth = 1};
    ID3D11DeviceContext_RSSetViewports(dx.ctx, 1, *vp);
    ID3D11DeviceContext_RSSetState(dx.ctx, dx.raster);
    ID3D11DeviceContext_OMSetRenderTargets(dx.ctx, 1, *dx.rtv, null);
    ID3D11DeviceContext_OMSetBlendState(dx.ctx, dx.blend, null, 0xffffffff);
    ID3D11DeviceContext_IASetPrimitiveTopology(dx.ctx, .TRIANGLESTRIP);
    ID3D11DeviceContext_VSSetShader(dx.ctx, dx.vs, null, 0);
    ID3D11DeviceContext_PSSetShader(dx.ctx, dx.ps, null, 0);
    ID3D11DeviceContext_VSSetShaderResources(dx.ctx, 1, 1, *dx.inst_srv);
    ID3D11DeviceContext_VSSetConstantBuffers(dx.ctx, 0, 1, *dx.cbuf);
    ID3D11DeviceContext_PSSetSamplers(dx.ctx, 0, 1, *dx.sampler);
    sr := D3D11_RECT.{0, 0, fb[0], fb[1]};
    ID3D11DeviceContext_RSSetScissorRects(dx.ctx, 1, *sr);

    Uniforms :: struct { viewport: [2]float32; base: u32; pad: u32; }
    zb := prof.zone_begin("gfx.batches");
    white := cast(*D3D_Tex, g.textures[g.white].native).srv;
    for b: batches {
        mapped: D3D11_MAPPED_SUBRESOURCE;
        if SUCCEEDED(ID3D11DeviceContext_Map(dx.ctx, dx.cbuf, 0, .WRITE_DISCARD, 0, *mapped)) {
            cast(*Uniforms, mapped.pData).* = .{viewport = .[cast(float32) fb[0], cast(float32) fb[1]], base = b.first};
            ID3D11DeviceContext_Unmap(dx.ctx, dx.cbuf, 0);
        }
        srvs: [TEX_SLOTS]*ID3D11ShaderResourceView;
        for * srvs  it.* = ifx it_index < b.n_slots then cast(*D3D_Tex, g.textures[b.slots[it_index]].native).srv else white;
        ID3D11DeviceContext_PSSetShaderResources(dx.ctx, 3, max(b.n_slots, 1), srvs.data);
        dt2 := cast(*D3D_Tex, g.textures[ifx b.tex2 then b.tex2 else g.white].native);
        ID3D11DeviceContext_PSSetShaderResources(dx.ctx, 19, 1, *dt2.srv);
        ID3D11DeviceContext_DrawInstanced(dx.ctx, 4, b.count, 0, 0);
    }
    prof.zone_end(zb);
    if timer {
        ID3D11DeviceContext_End(dx.ctx, timer.t1);
        ID3D11DeviceContext_End(dx.ctx, timer.disjoint);
        timer.frame = g.frame_index;
        timer.pending = true;
    }
    prof.zone("gfx.present");
    if dx.swap {
        // Sync interval 1 holds each resize frame to a vblank, so a fast drag replays stale sizes one refresh
        // at a time. Interval 0 on a flip swap chain still doesn't tear: DWM shows the newest frame.
        hr := IDXGISwapChain_Present(dx.swap, xx ifx platform.is_size_frame() then 0 else 1, 0);
        if FAILED(hr) {
            g.diag.present_fails += 1;
            note_failure(hr);
        }
    } else {
        ID3D11DeviceContext_Flush(dx.ctx);
    }
}

backend_texture_create :: (w: s32, h: s32, format: Texture_Format, pixels: []u8) -> *void {
    td := D3D11_TEXTURE2D_DESC.{
        Width = xx w, Height = xx h, MipLevels = 1, ArraySize = 1,
        Format = ifx format == .R8 then DXGI_FORMAT.R8_UNORM else ifx format == .RG8 then DXGI_FORMAT.R8G8_UNORM else .R8G8B8A8_UNORM,
        SampleDesc = .{Count = 1}, Usage = .DEFAULT, BindFlags = .SHADER_RESOURCE,
    };
    dt := New(D3D_Tex);
    init := D3D11_SUBRESOURCE_DATA.{pSysMem = pixels.data, SysMemPitch = cast(u32) (w * format_bpp(format))};
    hr := ID3D11Device_CreateTexture2D(dx.device, *td, ifx pixels then *init else null, *dt.tex);
    if FAILED(hr) {
        note_failure(hr);
        free(dt);
        return null;
    }
    hr = ID3D11Device_CreateShaderResourceView(dx.device, dt.tex, null, *dt.srv);
    if FAILED(hr) {
        note_failure(hr);
        IUnknown_Release(dt.tex);
        free(dt);
        return null;
    }
    return dt;
}

backend_texture_update :: (native: *void, format: Texture_Format, x: s32, y: s32, w: s32, h: s32, pixels: []u8, stride: s32) {
    box := D3D11_BOX.{left = xx x, top = xx y, front = 0, right = xx (x + w), bottom = xx (y + h), back = 1};
    ID3D11DeviceContext_UpdateSubresource(dx.ctx, cast(*D3D_Tex, native).tex, 0, *box, pixels.data, xx stride, 0);
}

backend_texture_destroy :: (native: *void) {
    dt := cast(*D3D_Tex) native;
    if dt == null return;
    IUnknown_Release(dt.srv);
    IUnknown_Release(dt.tex);
    free(dt);
}

backend_read_pixels :: (allocator: Allocator) -> []u8, int, int {
    if dx.offscreen == null return .[], 0, 0;
    w, h := cast(int) dx.back_size[0], cast(int) dx.back_size[1];
    td := D3D11_TEXTURE2D_DESC.{
        Width = xx w, Height = xx h, MipLevels = 1, ArraySize = 1,
        Format = .B8G8R8A8_UNORM, SampleDesc = .{Count = 1}, Usage = .STAGING, CPUAccessFlags = .READ,
    };
    staging: *ID3D11Texture2D;
    if FAILED(ID3D11Device_CreateTexture2D(dx.device, *td, null, *staging)) return .[], 0, 0;
    defer IUnknown_Release(staging);
    ID3D11DeviceContext_CopyResource(dx.ctx, staging, dx.offscreen);
    mapped: D3D11_MAPPED_SUBRESOURCE;
    if FAILED(ID3D11DeviceContext_Map(dx.ctx, staging, 0, .READ, 0, *mapped)) return .[], 0, 0;
    defer ID3D11DeviceContext_Unmap(dx.ctx, staging, 0);
    out := NewArray(w * h * 4, u8, initialized = false,, allocator);
    for y: 0..h-1 {
        row := cast(*u8) mapped.pData + y * mapped.RowPitch;
        for x: 0..w-1 {
            i, o := x * 4, (y * w + x) * 4;
            out[o + 0] = row[i + 2];
            out[o + 1] = row[i + 1];
            out[o + 2] = row[i + 0];
            out[o + 3] = row[i + 3];
        }
    }
    return out, w, h;
}

#scope_file

D3D_Tex :: struct {
    tex: *ID3D11Texture2D;
    srv: *ID3D11ShaderResourceView;
}

// GPU time per frame from timestamp queries, read back GPU_TIMERS frames later so nothing waits.
GPU_TIMERS :: 6;
Gpu_Timer :: struct {
    disjoint, t0, t1: *ID3D11Query;
    frame: u64;
    pending: bool;
}

dx: struct {
    device: *ID3D11Device;
    ctx: *ID3D11DeviceContext;
    swap: *IDXGISwapChain1;
    swap2: *IDXGISwapChain2;
    rtv: *ID3D11RenderTargetView;
    back_size: [2]s32;
    offscreen: *ID3D11Texture2D;
    vs: *ID3D11VertexShader;
    ps: *ID3D11PixelShader;
    blend: *ID3D11BlendState;
    raster: *ID3D11RasterizerState;
    sampler: *ID3D11SamplerState;
    inst_buf: *ID3D11Buffer;
    inst_srv: *ID3D11ShaderResourceView;
    inst_cap: int;
    cbuf: *ID3D11Buffer;
    swap_flags: DXGI_SWAP_CHAIN_FLAG;
    timers: [GPU_TIMERS]Gpu_Timer;
    idle_query: *ID3D11Query;
};

timer_read :: (t: *Gpu_Timer) {
    if !t.pending return;
    dj: D3D11_QUERY_DATA_TIMESTAMP_DISJOINT;
    a, b: u64;
    flags := cast(u32) D3D11_ASYNC_GETDATA_FLAG.D3D11_ASYNC_GETDATA_DONOTFLUSH;
    if ID3D11DeviceContext_GetData(dx.ctx, t.disjoint, *dj, size_of(type_of(dj)), flags) != S_OK return; // S_FALSE: not done yet
    t.pending = false;
    if dj.Disjoint || dj.Frequency == 0 return;
    if ID3D11DeviceContext_GetData(dx.ctx, t.t0, *a, size_of(u64), flags) != S_OK || ID3D11DeviceContext_GetData(dx.ctx, t.t1, *b, size_of(u64), flags) != S_OK return;
    if t.frame >= g.stats.gpu_frame {
        g.stats.gpu_ns = cast(s64) (cast(float64) (b - a) * 1000000000 / cast(float64) dj.Frequency);
        g.stats.gpu_frame = t.frame;
    }
}

compile :: (entry: string, target: string) -> string {
    code, errs, hr := D3DCompile(HLSL_SHADER_SRC, "fc_shader", .[], null, entry, target, 0, 0);
    defer free(errs);
    if FAILED(hr) {
        if errs  log_error("gfx: hlsl: %", errs);
        free(code);
        return "";
    }
    return code;
}

note_failure :: (hr: HRESULT) {
    g.diag.last_hresult = hr;
    g.diag.device_removed = ID3D11Device_GetDeviceRemovedReason(dx.device);
}

ensure_target :: (fb: [2]s32) -> bool {
    if dx.rtv && dx.back_size[0] == fb[0] && dx.back_size[1] == fb[1] return true;
    safe_release_and_reset(*dx.rtv);
    tex: *ID3D11Texture2D;
    if dx.swap {
        ID3D11DeviceContext_OMSetRenderTargets(dx.ctx, 0, null, null);
        if dx.back_size[0] || dx.back_size[1] {
            if FAILED(IDXGISwapChain_ResizeBuffers(dx.swap, 0, xx fb[0], xx fb[1], .UNKNOWN, xx dx.swap_flags)) return false;
        }
        IDXGISwapChain_GetBuffer(dx.swap, 0, *uid(ID3D11Texture2D_UUID), cast(**void) *tex);
    } else {
        safe_release(dx.offscreen);
        td := D3D11_TEXTURE2D_DESC.{
            Width = xx fb[0], Height = xx fb[1], MipLevels = 1, ArraySize = 1,
            Format = .B8G8R8A8_UNORM, SampleDesc = .{Count = 1}, Usage = .DEFAULT, BindFlags = .RENDER_TARGET,
        };
        ID3D11Device_CreateTexture2D(dx.device, *td, null, *dx.offscreen);
        tex = dx.offscreen;
        if tex  IUnknown_AddRef(tex);
    }
    if tex == null return false;
    ID3D11Device_CreateRenderTargetView(dx.device, tex, null, *dx.rtv);
    IUnknown_Release(tex);
    dx.back_size = fb;
    return true;
}

ensure_instances :: (n: int) {
    if dx.inst_cap >= n && dx.inst_buf return;
    safe_release(dx.inst_srv);
    safe_release(dx.inst_buf);
    dx.inst_cap = max(n, dx.inst_cap * 2, 4096);
    bd := D3D11_BUFFER_DESC.{
        ByteWidth = cast(u32) (dx.inst_cap * size_of(Instance)),
        Usage = .DYNAMIC,
        BindFlags = .SHADER_RESOURCE,
        CPUAccessFlags = .WRITE,
        MiscFlags = .BUFFER_STRUCTURED,
        StructureByteStride = size_of(Instance),
    };
    ID3D11Device_CreateBuffer(dx.device, *bd, null, *dx.inst_buf);
    srvd := D3D11_SHADER_RESOURCE_VIEW_DESC.{Format = .UNKNOWN, ViewDimension = .BUFFER};
    srvd.Buffer.NumElements = cast(u32) dx.inst_cap;
    ID3D11Device_CreateShaderResourceView(dx.device, dx.inst_buf, *srvd, *dx.inst_srv);
}
