// segment.jai's kernel on OpenGL 4.3 compute: an EGL context of its own with no surface, current only
// while a frame runs (capture threads come and go), M and F as shader storage buffers. libEGL is opened
// with dlopen, as the renderer does. Used under seg.mu only.

#scope_module

cs_init :: (m_floats: int) -> bool {
	lib := dlopen("libEGL.so.1", RTLD_NOW);
	if !lib || !load(*egl, "egl", lib) return false;
	client := egl.QueryString(null, EGL_EXTENSIONS);
	get_platform_display := cast(#type (platform: u32, native: *void, attribs: *s32) -> *void #c_call) egl.GetProcAddress("eglGetPlatformDisplayEXT");
	if client && contains(to_string(client), "EGL_MESA_platform_surfaceless") && get_platform_display
		cs.dpy = get_platform_display(EGL_PLATFORM_SURFACELESS_MESA, null, null);
	if !cs.dpy || !egl.Initialize(cs.dpy, null, null) {
		cs.dpy = egl.GetDisplay(null);
		if !cs.dpy || !egl.Initialize(cs.dpy, null, null) return false;
	}
	if !egl.BindAPI(EGL_OPENGL_API) return false;
	attrs := s32.[EGL_SURFACE_TYPE, 0, EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT, EGL_NONE];
	config: *void;
	n: s32;
	if !egl.ChooseConfig(cs.dpy, attrs.data, *config, 1, *n) || n < 1 return false;
	ctx_attrs := s32.[EGL_CONTEXT_MAJOR_VERSION, 4, EGL_CONTEXT_MINOR_VERSION, 3, EGL_CONTEXT_OPENGL_PROFILE_MASK, EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT, EGL_NONE];
	cs.ctx = egl.CreateContext(cs.dpy, config, null, ctx_attrs.data);
	if !cs.ctx || !current() return false;
	defer egl.MakeCurrent(cs.dpy, null, null, null);
	if !load(*gl, "gl", null) return false;

	src := temp_c_string(kernel_source(.GLSL));
	shader := gl.CreateShader(GL_COMPUTE_SHADER);
	gl.ShaderSource(shader, 1, *src, null);
	gl.CompileShader(shader);
	ok: s32;
	gl.GetShaderiv(shader, GL_COMPILE_STATUS, *ok);
	if !ok {
		log: [2048]u8;
		len: s32;
		gl.GetShaderInfoLog(shader, log.count, *len, log.data);
		log_error("video: segment kernel: %", to_string(log.data, len));
		return false;
	}
	cs.program = gl.CreateProgram();
	gl.AttachShader(cs.program, shader);
	gl.LinkProgram(cs.program);
	gl.GetProgramiv(cs.program, GL_LINK_STATUS, *ok);
	if !ok return false;
	gl.GenBuffers(3, cs.bufs.data);
	gl.BindBuffer(GL_UNIFORM_BUFFER, cs.bufs[2]);
	gl.BufferData(GL_UNIFORM_BUFFER, 64, null, GL_DYNAMIC_DRAW);
	gl.BindBuffer(GL_SHADER_STORAGE_BUFFER, cs.bufs[0]);
	gl.BufferData(GL_SHADER_STORAGE_BUFFER, m_floats * 4, null, GL_DYNAMIC_COPY);
	return gl.GetError() == 0;
}

cs_resize :: (bytes: int) -> bool {
	if !current() return false;
	gl.BindBuffer(GL_SHADER_STORAGE_BUFFER, cs.bufs[1]);
	gl.BufferData(GL_SHADER_STORAGE_BUFFER, bytes, null, GL_DYNAMIC_COPY);
	return gl.GetError() == 0;
}

cs_write_m :: (at: int, data: []float32) {
	if !current() return;
	gl.BindBuffer(GL_SHADER_STORAGE_BUFFER, cs.bufs[0]);
	gl.BufferSubData(GL_SHADER_STORAGE_BUFFER, at * 4, data.count * 4, data.data);
}

cs_write_f :: (at: int, data: []u8) {
	if !current() return;
	gl.BindBuffer(GL_SHADER_STORAGE_BUFFER, cs.bufs[1]);
	gl.BufferSubData(GL_SHADER_STORAGE_BUFFER, at, data.count, data.data);
}

cs_run :: (passes: []Pass) {
	if !current() return;
	gl.UseProgram(cs.program);
	gl.BindBufferBase(GL_SHADER_STORAGE_BUFFER, 0, cs.bufs[0]);
	gl.BindBufferBase(GL_SHADER_STORAGE_BUFFER, 1, cs.bufs[1]);
	gl.BindBufferBase(GL_UNIFORM_BUFFER, 0, cs.bufs[2]);
	gl.BindBuffer(GL_UNIFORM_BUFFER, cs.bufs[2]);
	for passes {
		gl.BufferSubData(GL_UNIFORM_BUFFER, 0, size_of(type_of(it.p)), it.p.data);
		gl.DispatchCompute(xx ((it.n + 63) / 64), 1, 1);
		gl.MemoryBarrier(GL_SHADER_STORAGE_BARRIER_BIT | GL_BUFFER_UPDATE_BARRIER_BIT);
	}
}

cs_read_f :: (at: int, out: []u8) -> bool {
	if !current() return false;
	defer egl.MakeCurrent(cs.dpy, null, null, null);
	gl.BindBuffer(GL_SHADER_STORAGE_BUFFER, cs.bufs[1]);
	gl.GetBufferSubData(GL_SHADER_STORAGE_BUFFER, at, out.count, out.data);
	return gl.GetError() == 0;
}

#scope_file

cs: struct {
	dpy, ctx: *void;
	program: u32;
	bufs: [3]u32; // M, F, the parameters
};

current :: () -> bool { return egl.MakeCurrent(cs.dpy, null, null, cs.ctx) != 0; }

// Fills every procedure field of table with <prefix><field name>, from lib or (lib null) eglGetProcAddress.
load :: (table: *$T, prefix: string, lib: *void) -> bool {
	for type_info(T).members {
		p := ifx lib then dlsym(lib, temp_c_string(join(prefix, it.name,, temp))) else egl.GetProcAddress(temp_c_string(join(prefix, it.name,, temp)));
		if !p return false;
		(cast(**void) (cast(*u8) table + it.offset_in_bytes)).* = p;
	}
	return true;
}

egl: struct {
	GetProcAddress: (name: *u8) -> *void #c_call;
	QueryString: (dpy: *void, name: s32) -> *u8 #c_call;
	GetDisplay: (native: *void) -> *void #c_call;
	Initialize: (dpy: *void, major: *s32, minor: *s32) -> u32 #c_call;
	BindAPI: (api: u32) -> u32 #c_call;
	ChooseConfig: (dpy: *void, attribs: *s32, configs: **void, size: s32, count: *s32) -> u32 #c_call;
	CreateContext: (dpy: *void, config: *void, share: *void, attribs: *s32) -> *void #c_call;
	MakeCurrent: (dpy: *void, draw: *void, read: *void, ctx: *void) -> u32 #c_call;
};

gl: struct {
	GetError: () -> u32 #c_call;
	CreateShader: (type: u32) -> u32 #c_call;
	ShaderSource: (shader: u32, count: s32, src: **u8, lengths: *s32) #c_call;
	CompileShader: (shader: u32) #c_call;
	GetShaderiv: (shader: u32, pname: u32, out: *s32) #c_call;
	GetShaderInfoLog: (shader: u32, size: s32, len: *s32, log: *u8) #c_call;
	CreateProgram: () -> u32 #c_call;
	AttachShader: (program: u32, shader: u32) #c_call;
	LinkProgram: (program: u32) #c_call;
	GetProgramiv: (program: u32, pname: u32, out: *s32) #c_call;
	UseProgram: (program: u32) #c_call;
	GenBuffers: (n: s32, out: *u32) #c_call;
	BindBuffer: (target: u32, buffer: u32) #c_call;
	BindBufferBase: (target: u32, index: u32, buffer: u32) #c_call;
	BufferData: (target: u32, size: int, data: *void, usage: u32) #c_call;
	BufferSubData: (target: u32, offset: int, size: int, data: *void) #c_call;
	GetBufferSubData: (target: u32, offset: int, size: int, data: *void) #c_call;
	DispatchCompute: (x: u32, y: u32, z: u32) #c_call;
	MemoryBarrier: (barriers: u32) #c_call;
};

EGL_NONE :: 0x3038;
EGL_EXTENSIONS :: 0x3055;
EGL_SURFACE_TYPE :: 0x3033;
EGL_RENDERABLE_TYPE :: 0x3040;
EGL_OPENGL_BIT :: 0x0008;
EGL_OPENGL_API :: 0x30A2;
EGL_CONTEXT_MAJOR_VERSION :: 0x3098;
EGL_CONTEXT_MINOR_VERSION :: 0x30FB;
EGL_CONTEXT_OPENGL_PROFILE_MASK :: 0x30FD;
EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT :: 0x0001;
EGL_PLATFORM_SURFACELESS_MESA :: 0x31DD;
GL_COMPUTE_SHADER :: 0x91B9;
GL_COMPILE_STATUS :: 0x8B81;
GL_LINK_STATUS :: 0x8B82;
GL_UNIFORM_BUFFER :: 0x8A11;
GL_SHADER_STORAGE_BUFFER :: 0x90D2;
GL_DYNAMIC_DRAW :: 0x88E8;
GL_DYNAMIC_COPY :: 0x88EA;
GL_SHADER_STORAGE_BARRIER_BIT :: 0x2000;
GL_BUFFER_UPDATE_BARRIER_BIT :: 0x200;
