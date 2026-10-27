// OpenGL 3.3 core through EGL: an X11 window surface, or (headless) a surfaceless context drawing into an
// FBO. libEGL is dlopen'ed and every GL entry point comes from eglGetProcAddress, so nothing but glibc is
// linked. Mirrors the D3D11 backend: same instances, blending, texture formats and readback layout.

#scope_module

backend_init :: () -> bool {
    lib := dlopen("libEGL.so.1", RTLD_NOW);
    if lib == null { log_error("gfx: libEGL.so.1 not found"); return false; }
    if !load_procs(*egl, "egl", lib) return false;
    headless := platform.is_headless();
    if !open_display(headless) { log_error("gfx: no EGL display (0x%)", formatInt(egl.GetError(), base = 16)); return false; }
    if !egl.BindAPI(EGL_OPENGL_API) { log_error("gfx: EGL has no desktop OpenGL"); return false; }

    config := choose_config(headless);
    if config == null { log_error("gfx: no EGL config"); return false; }
    ctx_attrs := s32.[EGL_CONTEXT_MAJOR_VERSION, 3, EGL_CONTEXT_MINOR_VERSION, 3,
        EGL_CONTEXT_OPENGL_PROFILE_MASK, EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT, EGL_NONE];
    st.ctx = egl.CreateContext(st.dpy, config, null, ctx_attrs.data);
    if st.ctx == null { log_error("gfx: no OpenGL 3.3 core context (0x%)", formatInt(egl.GetError(), base = 16)); return false; }
    if !headless {
        st.surface = egl.CreateWindowSurface(st.dpy, config, cast(u64) platform.native_window(), null);
        if st.surface == null { log_error("gfx: eglCreateWindowSurface failed (0x%)", formatInt(egl.GetError(), base = 16)); return false; }
    }
    // Headless: no surface at all (EGL_KHR_surfaceless_context); frames go to the FBO from ensure_target.
    if !egl.MakeCurrent(st.dpy, st.surface, st.surface, st.ctx) { log_error("gfx: eglMakeCurrent failed (0x%)", formatInt(egl.GetError(), base = 16)); return false; }
    if st.surface  egl.SwapInterval(st.dpy, 1);
    if !load_procs(*gl, "gl", null) return false;

    units: s32;
    gl.GetIntegerv(GL_MAX_TEXTURE_IMAGE_UNITS, *units);
    if units < TEX_SLOTS + 1 { log_error("gfx: % fragment texture units, need %", units, TEX_SLOTS + 1); return false; }
    st.program = link_program();
    if !st.program return false;

    // All state is set once here; backend_submit only changes attribute offsets and texture bindings.
    gl.UseProgram(st.program);
    slots: [TEX_SLOTS]s32;
    for * slots  it.* = xx it_index;
    gl.Uniform1iv(gl.GetUniformLocation(st.program, "texs"), TEX_SLOTS, slots.data);
    gl.Uniform1i(gl.GetUniformLocation(st.program, "tex2"), TEX_SLOTS);
    st.viewport_loc = gl.GetUniformLocation(st.program, "viewport");
    gl.GenVertexArrays(1, *st.vao);
    gl.BindVertexArray(st.vao);
    gl.GenBuffers(1, *st.inst_buf);
    gl.BindBuffer(GL_ARRAY_BUFFER, st.inst_buf);
    for 0..INST_ATTRS-1 {
        gl.EnableVertexAttribArray(xx it);
        gl.VertexAttribDivisor(xx it, 1);
    }
    gl.GenSamplers(1, *st.sampler);
    gl.SamplerParameteri(st.sampler, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    gl.SamplerParameteri(st.sampler, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    gl.SamplerParameteri(st.sampler, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    gl.SamplerParameteri(st.sampler, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    for 0..TEX_SLOTS  gl.BindSampler(xx it, st.sampler);
    gl.Enable(GL_BLEND);
    gl.BlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA); // premultiplied, colour and alpha alike (as D3D11)
    gl.Disable(GL_DITHER);
    gl.Disable(GL_FRAMEBUFFER_SRGB);              // UNORM targets, no sRGB conversion (as D3D11)
    gl.PixelStorei(GL_UNPACK_ALIGNMENT, 1);
    gl.PixelStorei(GL_PACK_ALIGNMENT, 1);
    for * st.timers  gl.GenQueries(1, *it.query);
    return true;
}

// The EGLDisplay (for importing video frames as EGLImages).
backend_native_device :: () -> *void { return st.dpy; }

backend_wait_idle :: () {
    if st.ctx  gl.Finish();
}

backend_shutdown :: () {
    // Destroying the context frees every GL object in it.
    if st.dpy {
        egl.MakeCurrent(st.dpy, null, null, null);
        if st.surface  egl.DestroySurface(st.dpy, st.surface);
        if st.ctx  egl.DestroyContext(st.dpy, st.ctx);
        egl.Terminate(st.dpy);
    }
    st = .{};
}

backend_submit :: (insts: []Instance, batches: []Batch, clear: Color, fb: [2]s32) {
    if fb[0] <= 0 || fb[1] <= 0 return;
    if !ensure_target(fb) return;
    for * st.timers timer_read(it);
    timer := *st.timers[g.frame_index % GPU_TIMERS];
    if timer.pending  timer = null; // still in flight from GPU_TIMERS frames ago: skip timing this frame
    else gl.BeginQuery(GL_TIME_ELAPSED, timer.query);
    // Re-specifying the store each frame lets the driver orphan the old one (no wait on the GPU).
    if insts  gl.BufferData(GL_ARRAY_BUFFER, insts.count * size_of(Instance), insts.data, GL_STREAM_DRAW);
    gl.Viewport(0, 0, fb[0], fb[1]);
    cc := premul(clear);
    gl.ClearColor(cc[0], cc[1], cc[2], cc[3]);
    gl.Clear(GL_COLOR_BUFFER_BIT);
    gl.Uniform2f(st.viewport_loc, xx fb[0], xx fb[1]);
    for b: batches {
        // GL 3.3 has no base instance: point the per-instance attributes at the batch's first instance.
        base := cast(int) b.first * size_of(Instance);
        for 0..INST_ATTRS-1  gl.VertexAttribPointer(xx it, 4, GL_FLOAT, GL_FALSE, size_of(Instance), cast(*void) (base + it * 16));
        for 0..cast(int) max(b.n_slots, 1) - 1  bind(it, ifx it < b.n_slots then b.slots[it] else g.white);
        bind(TEX_SLOTS, ifx b.tex2 then b.tex2 else g.white);
        gl.DrawArraysInstanced(GL_TRIANGLE_STRIP, 0, 4, xx b.count);
    }
    if timer {
        gl.EndQuery(GL_TIME_ELAPSED);
        timer.frame = g.frame_index;
        timer.pending = true;
    }
    if st.surface {
        if !egl.SwapBuffers(st.dpy, st.surface) {
            g.diag.present_fails += 1;
            g.diag.last_hresult = egl.GetError();
        }
    } else {
        gl.Flush();
    }
}

backend_texture_create :: (w: s32, h: s32, format: Texture_Format, pixels: []u8) -> *void {
    // No initial data: start zeroed, as D3D11 and Metal textures are in practice.
    zero: []u8;
    if !pixels  zero = NewArray(w * h * format_bpp(format), u8);
    defer array_free(zero);
    name: u32;
    gl.GenTextures(1, *name);
    gl.ActiveTexture(GL_TEXTURE0 + UPLOAD_UNIT);
    gl.BindTexture(GL_TEXTURE_2D, name);
    gl.GetError(); // clear a stale error so the check below is about this upload
    internal, fmt := gl_format(format);
    gl.PixelStorei(GL_UNPACK_ROW_LENGTH, 0);
    gl.TexImage2D(GL_TEXTURE_2D, 0, internal, w, h, 0, fmt, GL_UNSIGNED_BYTE, ifx pixels then pixels.data else zero.data);
    err := gl.GetError();
    if err != GL_NO_ERROR {
        g.diag.last_hresult = xx err;
        gl.DeleteTextures(1, *name);
        return null;
    }
    gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAX_LEVEL, 0);
    return cast(*void) cast(u64) name;
}

backend_texture_update :: (native: *void, format: Texture_Format, x: s32, y: s32, w: s32, h: s32, pixels: []u8, stride: s32) {
    gl.ActiveTexture(GL_TEXTURE0 + UPLOAD_UNIT);
    gl.BindTexture(GL_TEXTURE_2D, cast(u32) cast(u64) native);
    _, fmt := gl_format(format);
    gl.PixelStorei(GL_UNPACK_ROW_LENGTH, stride / cast(s32) format_bpp(format));
    gl.TexSubImage2D(GL_TEXTURE_2D, 0, x, y, w, h, fmt, GL_UNSIGNED_BYTE, pixels.data);
}

backend_texture_destroy :: (native: *void) {
    name := cast(u32) cast(u64) native;
    if name == 0 return;
    gl.DeleteTextures(1, *name); // also unbinds it from every unit
    for * st.bound if it.* == name  it.* = 0;
}

backend_read_pixels :: (allocator: Allocator) -> []u8, int, int {
    if st.fbo == 0 return .[], 0, 0;
    w, h := cast(int) st.size[0], cast(int) st.size[1];
    out := NewArray(w * h * 4, u8, initialized = false,, allocator);
    gl.ReadPixels(0, 0, xx w, xx h, GL_RGBA, GL_UNSIGNED_BYTE, out.data);
    // GL rows run bottom-up: flip to top row first.
    row := NewArray(w * 4, u8, initialized = false,, temp);
    for y: 0..h/2-1 {
        a, b := out.data + y * w * 4, out.data + (h - 1 - y) * w * 4;
        memcpy(row.data, a, w * 4);
        memcpy(a, b, w * 4);
        memcpy(b, row.data, w * 4);
    }
    return out, w, h;
}

#scope_file

libc :: #system_library "libc"; // glibc 2.17 keeps dl* in libdl, which the link step adds
dlopen :: (file: *u8, mode: s32) -> *void #foreign libc;
dlsym :: (handle: *void, name: *u8) -> *void #foreign libc;
RTLD_LAZY :: 1;
RTLD_NOW :: 2;
RTLD_NOLOAD :: 4;

INST_ATTRS :: size_of(Instance) / 16; // nine float4s, shader locations 0..8
UPLOAD_UNIT :: TEX_SLOTS + 1;         // texture uploads bind here, away from the units draws use

// GPU time per frame from GL_TIME_ELAPSED queries, read back GPU_TIMERS frames later so nothing waits.
GPU_TIMERS :: 6;
Gpu_Timer :: struct {
    query: u32;
    frame: u64;
    pending: bool;
}

st: struct {
    dpy, ctx, surface: *void;
    program: u32;
    viewport_loc: s32;
    vao, inst_buf, sampler: u32;
    fbo, rbo: u32;                // headless target
    size: [2]s32;                 // of the FBO
    bound: [TEX_SLOTS + 1]u32;    // texture name per unit, to skip redundant binds
    timers: [GPU_TIMERS]Gpu_Timer;
};

timer_read :: (t: *Gpu_Timer) {
    if !t.pending return;
    ready: s32;
    gl.GetQueryObjectiv(t.query, GL_QUERY_RESULT_AVAILABLE, *ready);
    if !ready return;
    t.pending = false;
    ns: u64;
    gl.GetQueryObjectui64v(t.query, GL_QUERY_RESULT, *ns);
    if t.frame >= g.stats.gpu_frame {
        g.stats.gpu_ns = cast(s64) ns;
        g.stats.gpu_frame = t.frame;
    }
}

bind :: (unit: int, t: Texture) {
    name := cast(u32) cast(u64) g.textures[t].native;
    if st.bound[unit] == name return;
    st.bound[unit] = name;
    gl.ActiveTexture(GL_TEXTURE0 + cast(u32) unit);
    gl.BindTexture(GL_TEXTURE_2D, name);
}

gl_format :: (f: Texture_Format) -> internal: s32, format: u32 {
    if f == {
        case .R8;  return GL_R8, GL_RED;
        case .RG8; return GL_RG8, GL_RG;
    }
    return GL_RGBA8, GL_RGBA;
}

ensure_target :: (fb: [2]s32) -> bool {
    if st.surface return true; // the window's default framebuffer follows the window
    if st.fbo && st.size[0] == fb[0] && st.size[1] == fb[1] return true;
    if !st.fbo {
        gl.GenFramebuffers(1, *st.fbo);
        gl.GenRenderbuffers(1, *st.rbo);
    }
    gl.BindRenderbuffer(GL_RENDERBUFFER, st.rbo);
    gl.RenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, fb[0], fb[1]);
    gl.BindFramebuffer(GL_FRAMEBUFFER, st.fbo);
    gl.FramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, st.rbo);
    if gl.CheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE return false;
    st.size = fb;
    return true;
}

open_display :: (headless: bool) -> bool {
    has :: (list: *u8, name: string) -> bool {
        if list == null return false;
        for split(to_string(list), " ",, temp) if it == name return true;
        return false;
    }
    try_init :: (dpy: *void) -> bool {
        st.dpy = dpy;
        return dpy != null && egl.Initialize(dpy, null, null) != 0;
    }
    client := egl.QueryString(null, EGL_EXTENSIONS); // null without EGL_EXT_client_extensions
    get_platform_display: (platform: u32, native: *void, attribs: *s32) -> *void #c_call;
    if has(client, "EGL_EXT_platform_base")  get_platform_display = cast(type_of(get_platform_display)) egl.GetProcAddress("eglGetPlatformDisplayEXT");
    if !headless {
        native := platform.native_display();
        if get_platform_display && (has(client, "EGL_KHR_platform_x11") || has(client, "EGL_EXT_platform_x11")) {
            if try_init(get_platform_display(EGL_PLATFORM_X11_KHR, native, null)) return true;
        }
        return try_init(egl.GetDisplay(native));
    }
    if !get_platform_display return false;
    if has(client, "EGL_MESA_platform_surfaceless") && try_init(get_platform_display(EGL_PLATFORM_SURFACELESS_MESA, null, null)) return true;
    if has(client, "EGL_EXT_platform_device") {
        query_devices := cast(#type (max: s32, devices: **void, count: *s32) -> u32 #c_call) egl.GetProcAddress("eglQueryDevicesEXT");
        devices: [16]*void;
        n: s32;
        if query_devices && query_devices(devices.count, devices.data, *n) {
            for 0..n-1 if try_init(get_platform_display(EGL_PLATFORM_DEVICE_EXT, devices[it], null)) return true;
        }
    }
    st.dpy = null;
    return false;
}

// Windowed: the config whose X visual is the window's (else the first plain 8-bit RGB one). Headless: any
// desktop-GL config; it only describes the context, which never gets a surface.
choose_config :: (headless: bool) -> *void {
    attrs := s32.[EGL_SURFACE_TYPE, xx ifx headless then 0 else EGL_WINDOW_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_NONE];
    configs: [64]*void;
    n: s32;
    if !egl.ChooseConfig(st.dpy, attrs.data, configs.data, configs.count, *n) || n <= 0 return null;
    if headless return configs[0];
    visual := window_visual();
    best: *void;
    for c: array_view(configs, 0, n) {
        vid, r, g, b: s32;
        egl.GetConfigAttrib(st.dpy, c, EGL_NATIVE_VISUAL_ID, *vid);
        if visual && cast(u64) vid == visual return c;
        egl.GetConfigAttrib(st.dpy, c, EGL_RED_SIZE, *r);
        egl.GetConfigAttrib(st.dpy, c, EGL_GREEN_SIZE, *g);
        egl.GetConfigAttrib(st.dpy, c, EGL_BLUE_SIZE, *b);
        if !best && r == 8 && g == 8 && b == 8  best = c;
    }
    return ifx best then best else configs[0];
}

// The X visual id of the platform's window, from the Xlib the platform layer already loaded; 0 if unknown.
window_visual :: () -> u64 {
    X_Window_Attributes :: struct {
        x, y, width, height, border_width, depth: s32;
        visual: *void;
        rest: [128]u8; // root, class, ... (136 bytes in all on x86_64)
    }
    x11 := dlopen("libX11.so.6", RTLD_LAZY | RTLD_NOLOAD);
    if x11 == null return 0;
    get_attributes := cast(#type (dpy: *void, window: u64, out: *X_Window_Attributes) -> s32 #c_call) dlsym(x11, "XGetWindowAttributes");
    visual_id := cast(#type (visual: *void) -> u64 #c_call) dlsym(x11, "XVisualIDFromVisual");
    a: X_Window_Attributes;
    if !get_attributes || !visual_id || !get_attributes(platform.native_display(), cast(u64) platform.native_window(), *a) || !a.visual return 0;
    return visual_id(a.visual);
}

link_program :: () -> u32 {
    compile :: (kind: u32, src: string) -> u32 {
        s := gl.CreateShader(kind);
        text, count := src.data, cast(s32) src.count;
        gl.ShaderSource(s, 1, *text, *count);
        gl.CompileShader(s);
        ok: s32;
        gl.GetShaderiv(s, GL_COMPILE_STATUS, *ok);
        if !ok {
            msg: [4096]u8;
            n: s32;
            gl.GetShaderInfoLog(s, msg.count, *n, msg.data);
            log_error("gfx: glsl: %", to_string(msg.data, n));
            gl.DeleteShader(s);
            return 0;
        }
        return s;
    }
    vs := compile(GL_VERTEX_SHADER, GLSL_VERTEX_SRC);
    fs := compile(GL_FRAGMENT_SHADER, GLSL_FRAGMENT_SRC);
    if !vs || !fs return 0;
    p := gl.CreateProgram();
    gl.AttachShader(p, vs);
    gl.AttachShader(p, fs);
    gl.LinkProgram(p);
    gl.DeleteShader(vs);
    gl.DeleteShader(fs);
    ok: s32;
    gl.GetProgramiv(p, GL_LINK_STATUS, *ok);
    if !ok {
        msg: [4096]u8;
        n: s32;
        gl.GetProgramInfoLog(p, msg.count, *n, msg.data);
        log_error("gfx: glsl link: %", to_string(msg.data, n));
        gl.DeleteProgram(p);
        return 0;
    }
    return p;
}

// Fills every procedure field of `table` with <prefix><field name>, from `lib` or (lib == null) eglGetProcAddress.
load_procs :: (table: *$T, prefix: string, lib: *void) -> bool {
    for type_info(T).members {
        name := tprint("%1%2\0", prefix, it.name);
        p := ifx lib then dlsym(lib, name.data) else egl.GetProcAddress(name.data);
        if p == null { log_error("gfx: % missing", slice(name, 0, name.count - 1)); return false; }
        (cast(**void) (cast(*u8) table + it.offset_in_bytes)).* = p;
    }
    return true;
}

// EGL 1.4 entry points from libEGL.so.1 (each field is "egl" + its name).
egl: struct {
    GetProcAddress: (name: *u8) -> *void #c_call;
    GetError: () -> s32 #c_call;
    QueryString: (dpy: *void, name: s32) -> *u8 #c_call;
    GetDisplay: (native: *void) -> *void #c_call;
    Initialize: (dpy: *void, major: *s32, minor: *s32) -> u32 #c_call;
    Terminate: (dpy: *void) -> u32 #c_call;
    BindAPI: (api: u32) -> u32 #c_call;
    ChooseConfig: (dpy: *void, attribs: *s32, configs: **void, size: s32, count: *s32) -> u32 #c_call;
    GetConfigAttrib: (dpy: *void, config: *void, attribute: s32, value: *s32) -> u32 #c_call;
    CreateContext: (dpy: *void, config: *void, share: *void, attribs: *s32) -> *void #c_call;
    DestroyContext: (dpy: *void, ctx: *void) -> u32 #c_call;
    CreateWindowSurface: (dpy: *void, config: *void, window: u64, attribs: *s32) -> *void #c_call;
    DestroySurface: (dpy: *void, surface: *void) -> u32 #c_call;
    MakeCurrent: (dpy: *void, draw: *void, read: *void, ctx: *void) -> u32 #c_call;
    SwapInterval: (dpy: *void, interval: s32) -> u32 #c_call;
    SwapBuffers: (dpy: *void, surface: *void) -> u32 #c_call;
};

// OpenGL 3.3 core entry points (each field is "gl" + its name).
gl: struct {
    GetError: () -> u32 #c_call;
    GetIntegerv: (pname: u32, data: *s32) #c_call;
    Enable: (cap: u32) #c_call;
    Disable: (cap: u32) #c_call;
    BlendFunc: (sfactor: u32, dfactor: u32) #c_call;
    Viewport: (x: s32, y: s32, width: s32, height: s32) #c_call;
    ClearColor: (r: float32, g: float32, b: float32, a: float32) #c_call;
    Clear: (mask: u32) #c_call;
    Flush: () #c_call;
    Finish: () #c_call;
    PixelStorei: (pname: u32, param: s32) #c_call;
    ReadPixels: (x: s32, y: s32, width: s32, height: s32, format: u32, type: u32, pixels: *void) #c_call;
    GenTextures: (n: s32, textures: *u32) #c_call;
    DeleteTextures: (n: s32, textures: *u32) #c_call;
    BindTexture: (target: u32, texture: u32) #c_call;
    ActiveTexture: (unit: u32) #c_call;
    TexImage2D: (target: u32, level: s32, internalformat: s32, width: s32, height: s32, border: s32, format: u32, type: u32, pixels: *void) #c_call;
    TexSubImage2D: (target: u32, level: s32, x: s32, y: s32, width: s32, height: s32, format: u32, type: u32, pixels: *void) #c_call;
    TexParameteri: (target: u32, pname: u32, param: s32) #c_call;
    GenSamplers: (n: s32, samplers: *u32) #c_call;
    BindSampler: (unit: u32, sampler: u32) #c_call;
    SamplerParameteri: (sampler: u32, pname: u32, param: s32) #c_call;
    GenBuffers: (n: s32, buffers: *u32) #c_call;
    BindBuffer: (target: u32, buffer: u32) #c_call;
    BufferData: (target: u32, size: s64, data: *void, usage: u32) #c_call;
    GenVertexArrays: (n: s32, arrays: *u32) #c_call;
    BindVertexArray: (array: u32) #c_call;
    EnableVertexAttribArray: (index: u32) #c_call;
    VertexAttribPointer: (index: u32, size: s32, type: u32, normalized: u8, stride: s32, pointer: *void) #c_call;
    VertexAttribDivisor: (index: u32, divisor: u32) #c_call;
    DrawArraysInstanced: (mode: u32, first: s32, count: s32, instancecount: s32) #c_call;
    CreateShader: (type: u32) -> u32 #c_call;
    ShaderSource: (shader: u32, count: s32, strings: **u8, lengths: *s32) #c_call;
    CompileShader: (shader: u32) #c_call;
    GetShaderiv: (shader: u32, pname: u32, params: *s32) #c_call;
    GetShaderInfoLog: (shader: u32, size: s32, length: *s32, log: *u8) #c_call;
    DeleteShader: (shader: u32) #c_call;
    CreateProgram: () -> u32 #c_call;
    AttachShader: (program: u32, shader: u32) #c_call;
    LinkProgram: (program: u32) #c_call;
    GetProgramiv: (program: u32, pname: u32, params: *s32) #c_call;
    GetProgramInfoLog: (program: u32, size: s32, length: *s32, log: *u8) #c_call;
    DeleteProgram: (program: u32) #c_call;
    UseProgram: (program: u32) #c_call;
    GetUniformLocation: (program: u32, name: *u8) -> s32 #c_call;
    Uniform1i: (location: s32, v: s32) #c_call;
    Uniform1iv: (location: s32, count: s32, v: *s32) #c_call;
    Uniform2f: (location: s32, x: float32, y: float32) #c_call;
    GenFramebuffers: (n: s32, framebuffers: *u32) #c_call;
    BindFramebuffer: (target: u32, framebuffer: u32) #c_call;
    FramebufferRenderbuffer: (target: u32, attachment: u32, rbtarget: u32, renderbuffer: u32) #c_call;
    CheckFramebufferStatus: (target: u32) -> u32 #c_call;
    GenRenderbuffers: (n: s32, renderbuffers: *u32) #c_call;
    BindRenderbuffer: (target: u32, renderbuffer: u32) #c_call;
    RenderbufferStorage: (target: u32, internalformat: u32, width: s32, height: s32) #c_call;
    GenQueries: (n: s32, ids: *u32) #c_call;
    BeginQuery: (target: u32, id: u32) #c_call;
    EndQuery: (target: u32) #c_call;
    GetQueryObjectiv: (id: u32, pname: u32, params: *s32) #c_call;
    GetQueryObjectui64v: (id: u32, pname: u32, params: *u64) #c_call;
};

// egl.h / eglext.h
EGL_NONE :: 0x3038;
EGL_EXTENSIONS :: 0x3055;
EGL_RED_SIZE :: 0x3024;
EGL_GREEN_SIZE :: 0x3023;
EGL_BLUE_SIZE :: 0x3022;
EGL_NATIVE_VISUAL_ID :: 0x302E;
EGL_SURFACE_TYPE :: 0x3033;
EGL_RENDERABLE_TYPE :: 0x3040;
EGL_WINDOW_BIT :: 0x0004;
EGL_OPENGL_BIT :: 0x0008;
EGL_OPENGL_API :: 0x30A2;
EGL_CONTEXT_MAJOR_VERSION :: 0x3098;
EGL_CONTEXT_MINOR_VERSION :: 0x30FB;
EGL_CONTEXT_OPENGL_PROFILE_MASK :: 0x30FD;
EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT :: 0x0001;
EGL_PLATFORM_X11_KHR :: 0x31D5;
EGL_PLATFORM_SURFACELESS_MESA :: 0x31DD;
EGL_PLATFORM_DEVICE_EXT :: 0x313F;

// gl.h / glcorearb.h
GL_NO_ERROR :: 0;
GL_FALSE :: 0;
GL_TRIANGLE_STRIP :: 0x0005;
GL_ONE :: 1;
GL_ONE_MINUS_SRC_ALPHA :: 0x0303;
GL_BLEND :: 0x0BE2;
GL_DITHER :: 0x0BD0;
GL_FRAMEBUFFER_SRGB :: 0x8DB9;
GL_COLOR_BUFFER_BIT :: 0x4000;
GL_UNPACK_ROW_LENGTH :: 0x0CF2;
GL_UNPACK_ALIGNMENT :: 0x0CF5;
GL_PACK_ALIGNMENT :: 0x0D05;
GL_MAX_TEXTURE_IMAGE_UNITS :: 0x8872;
GL_TEXTURE_2D :: 0x0DE1;
GL_TEXTURE0 :: 0x84C0;
GL_TEXTURE_MAG_FILTER :: 0x2800;
GL_TEXTURE_MIN_FILTER :: 0x2801;
GL_TEXTURE_WRAP_S :: 0x2802;
GL_TEXTURE_WRAP_T :: 0x2803;
GL_TEXTURE_MAX_LEVEL :: 0x813D;
GL_LINEAR :: 0x2601;
GL_CLAMP_TO_EDGE :: 0x812F;
GL_UNSIGNED_BYTE :: 0x1401;
GL_FLOAT :: 0x1406;
GL_RED :: 0x1903;
GL_RG :: 0x8227;
GL_RGBA :: 0x1908;
GL_R8 :: 0x8229;
GL_RG8 :: 0x822B;
GL_RGBA8 :: 0x8058;
GL_ARRAY_BUFFER :: 0x8892;
GL_STREAM_DRAW :: 0x88E0;
GL_VERTEX_SHADER :: 0x8B31;
GL_FRAGMENT_SHADER :: 0x8B30;
GL_COMPILE_STATUS :: 0x8B81;
GL_LINK_STATUS :: 0x8B82;
GL_FRAMEBUFFER :: 0x8D40;
GL_RENDERBUFFER :: 0x8D41;
GL_COLOR_ATTACHMENT0 :: 0x8CE0;
GL_FRAMEBUFFER_COMPLETE :: 0x8CD5;
GL_TIME_ELAPSED :: 0x88BF;
GL_QUERY_RESULT :: 0x8866;
GL_QUERY_RESULT_AVAILABLE :: 0x8867;
