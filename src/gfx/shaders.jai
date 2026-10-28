// Shared math for every shader language (MSL, HLSL, GLSL):
//  - quad = dst grown by softness (+1px AA margin), 4 verts as a triangle strip
//  - per-corner rounded-box SDF (pixels), coverage = clamp(0.5 - d) (1px AA)
//  - softness s > 0: coverage = 1 - smoothstep(-s, s, d)
//  - border b > 0: multiply by coverage outside the inner box (dst shrunk by b, radii - b)
//  - colors are premultiplied, bilinear across the dst rect
//  - tex kind 1: R8 coverage mask multiplies alpha; kind 2: RGBA premultiplied (gfx premultiplies on upload), tinted by color
//  - tex kind 3: NV12 video: tex = Y (R8), tex2 = CbCr (RG8), params.w = Yuv_Matrix
//  - params.z = kind + 4 * slot: the texture is the draw's texs[slot]
//  - the vertex shader clamps the quad to the instance's clip rect (no scissor)
//  - output premultiplied; blend One, OneMinusSrcAlpha

METAL_SHADER_SRC :: #string __END

#include <metal_stdlib>
using namespace metal;

struct Inst {
	float4 dst;
	float4 src;
	float4 c0, c1, c2, c3;
	float4 radii;
	float4 params;
	float4 clip;
};

struct Uniforms { float2 viewport; float2 pad; };

struct VOut {
	float4 pos [[position]];
	float2 p;        // pixel position
	float2 uv;       // texel position
	float2 local;    // 0..1 across dst (for gradient)
	float4 dst [[flat]];
	float4 radii [[flat]];
	float4 params [[flat]];
	float4 c0 [[flat]];
	float4 c1 [[flat]];
	float4 c2 [[flat]];
	float4 c3 [[flat]];
};

vertex VOut vs_main(uint vid [[vertex_id]], uint iid [[instance_id]],
                    const device Inst* insts [[buffer(0)]],
                    constant Uniforms& u [[buffer(1)]]) {
	Inst i = insts[iid];
	float2 corner = float2(float(vid & 1u), float(vid >> 1u));
	float grow = i.params.y + 1.0;
	if (i.params.z != 0.0 && i.params.y == 0.0) grow = 0.0; // textured, hard: exact quad
	float2 p0 = i.dst.xy - grow;
	float2 p1 = i.dst.zw + grow;
	float2 p = clamp(mix(p0, p1, corner), i.clip.xy, i.clip.zw);
	float2 t = (p - i.dst.xy) / max(i.dst.zw - i.dst.xy, float2(1e-4));
	VOut o;
	o.pos = float4(p / u.viewport * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
	o.p = p;
	o.uv = mix(i.src.xy, i.src.zw, t);
	o.local = t;
	o.dst = i.dst; o.radii = i.radii; o.params = i.params;
	o.c0 = i.c0; o.c1 = i.c1; o.c2 = i.c2; o.c3 = i.c3;
	return o;
}

static float sd_round_box(float2 p, float2 half_size, float4 r /* TL TR BL BR */) {
	float rad = p.y < 0.0 ? (p.x < 0.0 ? r.x : r.y) : (p.x < 0.0 ? r.z : r.w);
	float2 q = abs(p) - half_size + rad;
	return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - rad;
}

static float3 yuv_to_rgb(float y, float2 c, float m) {
	bool full = m >= 3.0;
	if (!full) { y = (y - 16.0/255.0) * (255.0/219.0); c = (c - 128.0/255.0) * (255.0/224.0); }
	else { c = c - 128.0/255.0; }
	bool bt709 = (m == 2.0 || m == 4.0);
	float3 rgb = bt709
		? float3(y + 1.5748*c.y, y - 0.187324*c.x - 0.468124*c.y, y + 1.8556*c.x)
		: float3(y + 1.402*c.y, y - 0.344136*c.x - 0.714136*c.y, y + 1.772*c.x);
	return saturate(rgb);
}

fragment float4 fs_main(VOut in [[stage_in]], array<texture2d<float>, 16> texs [[texture(0)]], texture2d<float> tex2 [[texture(16)]]) {
	constexpr sampler smp(coord::pixel, filter::linear, address::clamp_to_edge);
	float2 center = (in.dst.xy + in.dst.zw) * 0.5;
	float2 half_size = (in.dst.zw - in.dst.xy) * 0.5;
	float2 p = in.p - center;
	float border = in.params.x, soft = in.params.y;
	uint kz = uint(in.params.z);
	float kind = float(kz & 3u);
	texture2d<float> tex = texs[kz >> 2];

	float d = sd_round_box(p, half_size, in.radii);
	float cov;
	if (soft > 0.0) cov = 1.0 - smoothstep(-soft, soft, d);
	else cov = clamp(0.5 - d, 0.0, 1.0);
	if (border > 0.0) {
		float4 ir = max(in.radii - border, float4(0.0));
		float di = sd_round_box(p, max(half_size - border, float2(0.0)), ir);
		cov *= clamp(0.5 + di, 0.0, 1.0);
	}
	float2 t = clamp(in.local, 0.0, 1.0);
	float4 c = mix(mix(in.c0, in.c1, t.x), mix(in.c2, in.c3, t.x), t.y);
	if (kind == 1.0) {
		c *= tex.sample(smp, in.uv).r;
	} else if (kind == 2.0) {
		c *= tex.sample(smp, in.uv);
	} else if (kind == 3.0) {
		float y = tex.sample(smp, in.uv).r;
		float2 scale2 = float2(tex2.get_width(), tex2.get_height()) / float2(tex.get_width(), tex.get_height());
		float2 cc = tex2.sample(smp, in.uv * scale2).rg;
		c *= float4(yuv_to_rgb(y, cc, in.params.w), 1.0);
	}
	return c * cov;
}
__END
;

HLSL_SHADER_SRC :: #string __END

struct Inst {
	float4 dst;
	float4 src;
	float4 c0, c1, c2, c3;
	float4 radii;
	float4 params;
	float4 clip;
};
StructuredBuffer<Inst> insts : register(t1);
// After texs, not t2: on this laptop (Intel UHD + RTX 4050) an optimised build sampled t2 as white,
// turning every video magenta, though the bound view and its texture were right.
Texture2D tex2 : register(t19);
Texture2D texs[16] : register(t3);
SamplerState smp : register(s0);

// SM 5.0 can't index a texture array with a variable, hence the switch. No mips, so SampleLevel
// (which needs no derivatives and is fine in flow control).
float4 sample_slot(uint slot, float2 uv, out float2 dims) {
	uint w, h;
	switch (slot) {
	case 0: texs[0].GetDimensions(w, h); break;
	case 1: texs[1].GetDimensions(w, h); break;
	case 2: texs[2].GetDimensions(w, h); break;
	case 3: texs[3].GetDimensions(w, h); break;
	case 4: texs[4].GetDimensions(w, h); break;
	case 5: texs[5].GetDimensions(w, h); break;
	case 6: texs[6].GetDimensions(w, h); break;
	case 7: texs[7].GetDimensions(w, h); break;
	case 8: texs[8].GetDimensions(w, h); break;
	case 9: texs[9].GetDimensions(w, h); break;
	case 10: texs[10].GetDimensions(w, h); break;
	case 11: texs[11].GetDimensions(w, h); break;
	case 12: texs[12].GetDimensions(w, h); break;
	case 13: texs[13].GetDimensions(w, h); break;
	case 14: texs[14].GetDimensions(w, h); break;
	default: texs[15].GetDimensions(w, h); break;
	}
	dims = float2(w, h);
	float2 t = uv / dims;
	switch (slot) {
	case 0: return texs[0].SampleLevel(smp, t, 0);
	case 1: return texs[1].SampleLevel(smp, t, 0);
	case 2: return texs[2].SampleLevel(smp, t, 0);
	case 3: return texs[3].SampleLevel(smp, t, 0);
	case 4: return texs[4].SampleLevel(smp, t, 0);
	case 5: return texs[5].SampleLevel(smp, t, 0);
	case 6: return texs[6].SampleLevel(smp, t, 0);
	case 7: return texs[7].SampleLevel(smp, t, 0);
	case 8: return texs[8].SampleLevel(smp, t, 0);
	case 9: return texs[9].SampleLevel(smp, t, 0);
	case 10: return texs[10].SampleLevel(smp, t, 0);
	case 11: return texs[11].SampleLevel(smp, t, 0);
	case 12: return texs[12].SampleLevel(smp, t, 0);
	case 13: return texs[13].SampleLevel(smp, t, 0);
	case 14: return texs[14].SampleLevel(smp, t, 0);
	default: return texs[15].SampleLevel(smp, t, 0);
	}
}
cbuffer Uniforms : register(b0) { float2 viewport; uint base_instance; uint pad; };

struct VOut {
	float4 pos : SV_Position;
	float2 p : P;
	float2 uv : UV;
	float2 local : LOCAL;
	nointerpolation float4 dst : DST;
	nointerpolation float4 radii : RADII;
	nointerpolation float4 params : PARAMS;
	nointerpolation float4 c0 : C0;
	nointerpolation float4 c1 : C1;
	nointerpolation float4 c2 : C2;
	nointerpolation float4 c3 : C3;
};

VOut vs_main(uint vid : SV_VertexID, uint iid : SV_InstanceID) {
	Inst i = insts[iid + base_instance];
	float2 corner = float2(float(vid & 1u), float(vid >> 1u));
	float grow = i.params.y + 1.0;
	if (i.params.z != 0.0 && i.params.y == 0.0) grow = 0.0;
	float2 p0 = i.dst.xy - grow;
	float2 p1 = i.dst.zw + grow;
	float2 p = clamp(lerp(p0, p1, corner), i.clip.xy, i.clip.zw);
	float2 t = (p - i.dst.xy) / max(i.dst.zw - i.dst.xy, float2(1e-4, 1e-4));
	VOut o;
	o.pos = float4(p / viewport * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
	o.p = p;
	o.uv = lerp(i.src.xy, i.src.zw, t);
	o.local = t;
	o.dst = i.dst; o.radii = i.radii; o.params = i.params;
	o.c0 = i.c0; o.c1 = i.c1; o.c2 = i.c2; o.c3 = i.c3;
	return o;
}

float sd_round_box(float2 p, float2 half_size, float4 r) {
	float rad = p.y < 0.0 ? (p.x < 0.0 ? r.x : r.y) : (p.x < 0.0 ? r.z : r.w);
	float2 q = abs(p) - half_size + rad;
	return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - rad;
}

float3 yuv_to_rgb(float y, float2 c, float m) {
	bool full = m >= 3.0;
	if (!full) { y = (y - 16.0/255.0) * (255.0/219.0); c = (c - 128.0/255.0) * (255.0/224.0); }
	else { c = c - 128.0/255.0; }
	bool bt709 = (m == 2.0 || m == 4.0);
	float3 rgb = bt709
		? float3(y + 1.5748*c.y, y - 0.187324*c.x - 0.468124*c.y, y + 1.8556*c.x)
		: float3(y + 1.402*c.y, y - 0.344136*c.x - 0.714136*c.y, y + 1.772*c.x);
	return saturate(rgb);
}

float4 ps_main(VOut i) : SV_Target {
	float2 center = (i.dst.xy + i.dst.zw) * 0.5;
	float2 half_size = (i.dst.zw - i.dst.xy) * 0.5;
	float2 p = i.p - center;
	float border = i.params.x, soft = i.params.y;
	uint kz = (uint)i.params.z;
	uint kind = kz & 3u;
	float d = sd_round_box(p, half_size, i.radii);
	float cov;
	if (soft > 0.0) cov = 1.0 - smoothstep(-soft, soft, d);
	else cov = saturate(0.5 - d);
	if (border > 0.0) {
		float4 ir = max(i.radii - border, float4(0, 0, 0, 0));
		float di = sd_round_box(p, max(half_size - border, float2(0, 0)), ir);
		cov *= saturate(0.5 + di);
	}
	float2 t = saturate(i.local);
	float4 c = lerp(lerp(i.c0, i.c1, t.x), lerp(i.c2, i.c3, t.x), t.y);
	if (kind != 0u) {
		float2 dims;
		float4 s = sample_slot(kz >> 2, i.uv, dims);
		if (kind == 1u) c *= s.r;
		else if (kind == 3u) {
			float2 cc = tex2.SampleLevel(smp, i.uv / dims, 0).rg;
			c *= float4(yuv_to_rgb(s.r, cc, i.params.w), 1.0);
		}
		else c *= s;
	}
	return c * cov;
}
__END
;

// GLSL 3.30 (OpenGL on Linux): the HLSL path, with the instance as per-instance vertex attributes
// (locations 0..8 = Instance's nine float4s; the backend points them at the batch's first instance).
GLSL_VERTEX_SRC :: #string __END
#version 330 core
layout(location = 0) in vec4 dst;
layout(location = 1) in vec4 src;
layout(location = 2) in vec4 c0;
layout(location = 3) in vec4 c1;
layout(location = 4) in vec4 c2;
layout(location = 5) in vec4 c3;
layout(location = 6) in vec4 radii;
layout(location = 7) in vec4 params;
layout(location = 8) in vec4 clip;
uniform vec2 viewport;

out vec2 v_p;
out vec2 v_uv;
out vec2 v_local;
flat out vec4 v_dst, v_radii, v_params, v_c0, v_c1, v_c2, v_c3;

void main() {
	vec2 corner = vec2(float(gl_VertexID & 1), float(gl_VertexID >> 1));
	float grow = params.y + 1.0;
	if (params.z != 0.0 && params.y == 0.0) grow = 0.0;
	vec2 p0 = dst.xy - grow;
	vec2 p1 = dst.zw + grow;
	vec2 p = min(max(mix(p0, p1, corner), clip.xy), clip.zw); // HLSL clamp
	vec2 t = (p - dst.xy) / max(dst.zw - dst.xy, vec2(1e-4));
	gl_Position = vec4(p / viewport * vec2(2.0, -2.0) + vec2(-1.0, 1.0), 0.0, 1.0);
	v_p = p;
	v_uv = mix(src.xy, src.zw, t);
	v_local = t;
	v_dst = dst; v_radii = radii; v_params = params;
	v_c0 = c0; v_c1 = c1; v_c2 = c2; v_c3 = c3;
}
__END
;

GLSL_FRAGMENT_SRC :: #string __END
#version 330 core
in vec2 v_p;
in vec2 v_uv;
in vec2 v_local;
flat in vec4 v_dst, v_radii, v_params, v_c0, v_c1, v_c2, v_c3;
uniform sampler2D texs[16];
uniform sampler2D tex2;
layout(location = 0) out vec4 frag;

// GLSL 3.30 indexes sampler arrays only with constants, hence the switch (as in HLSL). No mips: textureLod.
#define SLOT(n) case n: dims = vec2(textureSize(texs[n], 0)); s = textureLod(texs[n], uv / dims, 0.0); break;
vec4 sample_slot(int slot, vec2 uv, out vec2 dims) {
	vec4 s;
	switch (slot) {
	SLOT(0) SLOT(1) SLOT(2) SLOT(3) SLOT(4) SLOT(5) SLOT(6) SLOT(7)
	SLOT(8) SLOT(9) SLOT(10) SLOT(11) SLOT(12) SLOT(13) SLOT(14)
	default: dims = vec2(textureSize(texs[15], 0)); s = textureLod(texs[15], uv / dims, 0.0); break;
	}
	return s;
}

float sd_round_box(vec2 p, vec2 half_size, vec4 r) {
	float rad = p.y < 0.0 ? (p.x < 0.0 ? r.x : r.y) : (p.x < 0.0 ? r.z : r.w);
	vec2 q = abs(p) - half_size + rad;
	return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - rad;
}

vec3 yuv_to_rgb(float y, vec2 c, float m) {
	bool full = m >= 3.0;
	if (!full) { y = (y - 16.0/255.0) * (255.0/219.0); c = (c - 128.0/255.0) * (255.0/224.0); }
	else { c = c - 128.0/255.0; }
	bool bt709 = (m == 2.0 || m == 4.0);
	vec3 rgb = bt709
		? vec3(y + 1.5748*c.y, y - 0.187324*c.x - 0.468124*c.y, y + 1.8556*c.x)
		: vec3(y + 1.402*c.y, y - 0.344136*c.x - 0.714136*c.y, y + 1.772*c.x);
	return clamp(rgb, 0.0, 1.0);
}

void main() {
	vec2 center = (v_dst.xy + v_dst.zw) * 0.5;
	vec2 half_size = (v_dst.zw - v_dst.xy) * 0.5;
	vec2 p = v_p - center;
	float border = v_params.x, soft = v_params.y;
	uint kz = uint(v_params.z);
	uint kind = kz & 3u;
	float d = sd_round_box(p, half_size, v_radii);
	float cov;
	if (soft > 0.0) cov = 1.0 - smoothstep(-soft, soft, d);
	else cov = clamp(0.5 - d, 0.0, 1.0);
	if (border > 0.0) {
		vec4 ir = max(v_radii - border, vec4(0.0));
		float di = sd_round_box(p, max(half_size - border, vec2(0.0)), ir);
		cov *= clamp(0.5 + di, 0.0, 1.0);
	}
	vec2 t = clamp(v_local, 0.0, 1.0);
	vec4 c = mix(mix(v_c0, v_c1, t.x), mix(v_c2, v_c3, t.x), t.y);
	if (kind != 0u) {
		vec2 dims;
		vec4 s = sample_slot(int(kz >> 2u), v_uv, dims);
		if (kind == 1u) c *= s.r;
		else if (kind == 3u) {
			vec2 cc = textureLod(tex2, v_uv / dims, 0.0).rg;
			c *= vec4(yuv_to_rgb(s.r, cc, v_params.w), 1.0);
		}
		else c *= s;
	}
	frag = c * cov;
}
__END
;

// Vector scenes (vector/scene.jai has the model). A scene is one pass and one draw: every instance is a
// quad whose fragments read and write the pixel's whole layer stack in order (programmable blending,
// one raster order group). Attachment 0 is the output (slot 0, premultiplied RGBA8), attachments 1..6
// the nested layers (slots 1..6, tile memory only). Coverage is exact area, as on the CPU:
//  - Fill (kind 0): coverage = sum over segs d.x .. d.x + d.y of dir * the area of the pixel right of the
//    line within its rows, by rule (c.z & 1); blends into slot c.y by mode (c.z / 2)
//  - Composite (kind 1): slot c.y over the one below with opacity a.x and pops it; with a matte (a.y),
//    slot c.y is the matte (opacity a.z) for the source below it, and both pop
//  - Mask_Apply (kind 2): the slot below c.y *= slot c.y's alpha, and c.y pops

METAL_SCENE_SRC :: #string __END

#include <metal_stdlib>
using namespace metal;

struct SInst { float4 a; float4 b; float4 c; float4 d; };
struct SGrad { float4 m0; float4 m1; float4 p; float4 pad; }; // inv[0..3]; inv[4..5], radial, spread; p0, p1; r, fr

struct SVOut {
	float4 pos [[position]];
	float4 a [[flat]];
	float4 c [[flat]];
	float4 d [[flat]];
};

vertex SVOut vs_scene(uint vid [[vertex_id]], uint iid [[instance_id]],
                      const device SInst* insts [[buffer(0)]],
                      constant float2& vp [[buffer(1)]]) {
	SInst i = insts[iid];
	float2 corner = float2(float(vid & 1u), float(vid >> 1u));
	float2 p = mix(i.b.xy, i.b.zw, corner);
	SVOut o;
	o.pos = float4(p / vp * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
	o.a = i.a;
	o.c = i.c;
	o.d = i.d;
	return o;
}

struct SOut {
	float4 l0 [[color(0), raster_order_group(0)]];
	float4 l1 [[color(1), raster_order_group(0)]];
	float4 l2 [[color(2), raster_order_group(0)]];
	float4 l3 [[color(3), raster_order_group(0)]];
	float4 l4 [[color(4), raster_order_group(0)]];
	float4 l5 [[color(5), raster_order_group(0)]];
	float4 l6 [[color(6), raster_order_group(0)]];
};

// Mean over u in [u0, u1] of clamp(1 - u, 0, 1): the part of a pixel row right of the line, with u the
// line's x relative to the pixel's left side.
static float right_of(float u0, float u1) {
	if (max(u0, u1) <= 0.0) return 1.0;
	if (min(u0, u1) >= 1.0) return 0.0;
	if (abs(u1 - u0) < 1e-3) return clamp(1.0 - 0.5 * (u0 + u1), 0.0, 1.0);
	// antiderivative of clamp(1 - u, 0, 1)
	auto G = [](float u) { return u <= 0.0 ? u : (u >= 1.0 ? 0.5 : u - 0.5 * u * u); };
	return (G(u1) - G(u0)) / (u1 - u0);
}

static float edge_area(float4 e, float2 px) {
	float2 a = e.xy, b = e.zw;
	float dir = 1.0;
	if (a.y > b.y) { float2 t = a; a = b; b = t; dir = -1.0; }
	float y0 = max(a.y, px.y), y1 = min(b.y, px.y + 1.0);
	if (y1 <= y0) return 0.0;
	float dxdy = (b.x - a.x) / (b.y - a.y);
	float x0 = a.x + (y0 - a.y) * dxdy, x1 = a.x + (y1 - a.y) * dxdy;
	return dir * (y1 - y0) * right_of(x0 - px.x, x1 - px.x);
}

static float4 ramp_at(const device uchar4* ramps, int g, float t) {
	float x = clamp(t * 256.0 - 0.5, 0.0, 255.0);
	int i0 = int(floor(x));
	int i1 = min(i0 + 1, 255);
	float4 c0 = float4(ramps[g * 256 + i0]) / 255.0, c1 = float4(ramps[g * 256 + i1]) / 255.0;
	return mix(c0, c1, x - float(i0));
}

// Straight RGBA of gradient g at pixel center p; alpha 0 where a conical gradient is undefined.
static float4 gradient(const device SGrad* grads, const device uchar4* ramps, int g, float2 p) {
	SGrad gr = grads[g];
	float2 q = float2(gr.m0.x * p.x + gr.m0.z * p.y + gr.m1.x, gr.m0.y * p.x + gr.m0.w * p.y + gr.m1.y);
	float2 p0 = gr.p.xy, p1 = gr.p.zw;
	float r = gr.pad.x, fr = gr.pad.y;
	float t;
	if (gr.m1.z < 0.5) {
		float2 d = p1 - p0;
		float l2 = dot(d, d);
		t = l2 <= 0.0 ? 0.0 : dot(q - p0, d) / l2;
	} else {
		// circles C(t) = f + t * (c - f), radius fr + t * (r - fr); the largest t with radius >= 0
		float2 f = p1, cd = p0 - p1, qf = q - f;
		float dr = r - fr;
		float A = dot(cd, cd) - dr * dr;
		float B = dot(qf, cd) + fr * dr;
		float C = dot(qf, qf) - fr * fr;
		if (abs(A) < 1e-9) {
			if (abs(B) < 1e-12) return float4(0.0);
			t = C / (2.0 * B);
			if (fr + t * dr < 0.0) return float4(0.0);
		} else {
			float disc = B * B - A * C;
			if (disc < 0.0) return float4(0.0);
			float s = sqrt(disc);
			float hi = max((B + s) / A, (B - s) / A), lo = min((B + s) / A, (B - s) / A);
			if (fr + hi * dr >= 0.0) t = hi;
			else if (fr + lo * dr >= 0.0) t = lo;
			else return float4(0.0);
		}
	}
	float spread = gr.m1.w;
	if (spread < 0.5) t = clamp(t, 0.0, 1.0);
	else if (spread < 1.5) { t = abs(t); float k = floor(t); t -= k; if (fmod(k, 2.0) == 1.0) t = 1.0 - t; } // reflect
	else t = t - floor(t); // repeat
	return ramp_at(ramps, g, t);
}

fragment SOut fs_scene(SVOut in [[stage_in]],
                       float4 l0 [[color(0), raster_order_group(0)]],
                       float4 l1 [[color(1), raster_order_group(0)]],
                       float4 l2 [[color(2), raster_order_group(0)]],
                       float4 l3 [[color(3), raster_order_group(0)]],
                       float4 l4 [[color(4), raster_order_group(0)]],
                       float4 l5 [[color(5), raster_order_group(0)]],
                       float4 l6 [[color(6), raster_order_group(0)]],
                       const device SGrad* grads [[buffer(0)]],
                       const device uchar4* ramps [[buffer(1)]],
                       const device float4* segs [[buffer(2)]]) {
	float4 L[7] = { l0, l1, l2, l3, l4, l5, l6 };
	int kind = int(in.c.x);
	int top = int(in.c.y);
	if (kind == 0) {
		float2 px = floor(in.pos.xy);
		int first = int(in.d.x), n = int(in.d.y);
		float acc = 0.0;
		for (int i = 0; i < n; i++) acc += edge_area(segs[first + i], px);
		float v = abs(acc);
		float cov;
		int rm = int(in.c.z);
		if ((rm & 1) == 0) cov = min(v, 1.0);
		else { v = v - 2.0 * floor(v / 2.0); cov = v > 1.0 ? 2.0 - v : v; }
		int mode = rm >> 1;
		float4 d = L[top];
		if (mode == 0) {
			float4 col = in.a;
			int g = int(in.c.w);
			if (g >= 0) col = gradient(grads, ramps, g, in.pos.xy);
			float al = col.a * cov;
			d = float4(col.rgb * al, al) + d * (1.0 - al);
		} else if (mode == 1) {
			d *= cov;
		} else {
			float c = cov * in.a.x;
			if (in.a.y > 0.5) c = 1.0 - c;
			float m = d.a;
			switch (mode) {
			case 2: m = c; break;
			case 3: m = 1.0 - c; break;
			case 4: m = m + c - m * c; break;
			case 5: m = m * (1.0 - c); break;
			case 6: m = m * c; break;
			case 7: m = max(m, c); break;
			case 8: m = min(m, c); break;
			case 9: m = abs(m - c); break;
			}
			d = float4(m);
		}
		L[top] = d;
	} else if (kind == 1) {
		int mk = int(in.a.y);
		int src = mk != 0 ? top - 1 : top;
		float4 s = L[src];
		if (mk != 0) {
			float4 mt = L[top];
			float f = (mk >= 3 ? dot(mt.rgb, float3(0.2125, 0.7154, 0.0721)) : mt.a) * in.a.z;
			if (mk == 2 || mk == 4) f = 1.0 - f;
			s *= f;
			L[top] = float4(0.0);
		}
		L[src] = float4(0.0);
		float al = s.a * in.a.x;
		L[src - 1] = s * in.a.x + L[src - 1] * (1.0 - al);
	} else {
		L[top - 1] *= L[top].a;
		L[top] = float4(0.0);
	}
	SOut o;
	o.l0 = L[0]; o.l1 = L[1]; o.l2 = L[2]; o.l3 = L[3]; o.l4 = L[4]; o.l5 = L[5]; o.l6 = L[6];
	return o;
}
__END
;

// The same scenes for GL (and, in HLSL below, D3D11), which can't read the framebuffer: gfx.scene_plan
// turns a scene into draws into one layer texture at a time with fixed-function blending, so a Fill
// outputs what its blend state needs (paint * coverage for Over, coverage for Multiply, the mask value
// for the mask blends), a Composite its source layer (times a matte) and a Mask_Apply the mask's alpha.
// Scenes draw unflipped (pixel row 0 = texture row 0), like uploaded textures. segs, grads and ramps
// are texture buffers; src and matte the layers a Composite or Mask_Apply reads.

GLSL_SCENE_VERTEX_SRC :: #string __END
#version 330 core
layout(location = 0) in vec4 ia;
layout(location = 1) in vec4 ib;
layout(location = 2) in vec4 ic;
layout(location = 3) in vec4 id;
uniform vec2 viewport;
flat out vec4 va, vc, vd;

void main() {
	vec2 corner = vec2(float(gl_VertexID & 1), float(gl_VertexID >> 1));
	vec2 p = mix(ib.xy, ib.zw, corner);
	gl_Position = vec4(p / viewport * 2.0 - 1.0, 0.0, 1.0);
	va = ia; vc = ic; vd = id;
}
__END
;

GLSL_SCENE_FRAGMENT_SRC :: #string __END
#version 330 core
flat in vec4 va, vc, vd;
uniform samplerBuffer segs;
uniform samplerBuffer grads;
uniform samplerBuffer ramps;
uniform sampler2D src_layer;
uniform sampler2D matte_layer;
out vec4 frag;

float G(float u) { return u <= 0.0 ? u : (u >= 1.0 ? 0.5 : u - 0.5 * u * u); }

float right_of(float u0, float u1) {
	if (max(u0, u1) <= 0.0) return 1.0;
	if (min(u0, u1) >= 1.0) return 0.0;
	if (abs(u1 - u0) < 1e-3) return clamp(1.0 - 0.5 * (u0 + u1), 0.0, 1.0);
	return (G(u1) - G(u0)) / (u1 - u0);
}

float edge_area(vec4 e, vec2 px) {
	vec2 a = e.xy, b = e.zw;
	float dir = 1.0;
	if (a.y > b.y) { vec2 t = a; a = b; b = t; dir = -1.0; }
	float y0 = max(a.y, px.y), y1 = min(b.y, px.y + 1.0);
	if (y1 <= y0) return 0.0;
	float dxdy = (b.x - a.x) / (b.y - a.y);
	float x0 = a.x + (y0 - a.y) * dxdy, x1 = a.x + (y1 - a.y) * dxdy;
	return dir * (y1 - y0) * right_of(x0 - px.x, x1 - px.x);
}

vec4 ramp_at(int g, float t) {
	float x = clamp(t * 256.0 - 0.5, 0.0, 255.0);
	int i0 = int(floor(x));
	int i1 = min(i0 + 1, 255);
	return mix(texelFetch(ramps, g * 256 + i0), texelFetch(ramps, g * 256 + i1), x - float(i0));
}

vec4 gradient(int g, vec2 p) {
	vec4 m0 = texelFetch(grads, g * 4), m1 = texelFetch(grads, g * 4 + 1), pp = texelFetch(grads, g * 4 + 2), rr = texelFetch(grads, g * 4 + 3);
	vec2 q = vec2(m0.x * p.x + m0.z * p.y + m1.x, m0.y * p.x + m0.w * p.y + m1.y);
	vec2 p0 = pp.xy, p1 = pp.zw;
	float r = rr.x, fr = rr.y;
	float t;
	if (m1.z < 0.5) {
		vec2 d = p1 - p0;
		float l2 = dot(d, d);
		t = l2 <= 0.0 ? 0.0 : dot(q - p0, d) / l2;
	} else {
		vec2 f = p1, cd = p0 - p1, qf = q - f;
		float dr = r - fr;
		float A = dot(cd, cd) - dr * dr;
		float B = dot(qf, cd) + fr * dr;
		float C = dot(qf, qf) - fr * fr;
		if (abs(A) < 1e-9) {
			if (abs(B) < 1e-12) return vec4(0.0);
			t = C / (2.0 * B);
			if (fr + t * dr < 0.0) return vec4(0.0);
		} else {
			float disc = B * B - A * C;
			if (disc < 0.0) return vec4(0.0);
			float s = sqrt(disc);
			float hi = max((B + s) / A, (B - s) / A), lo = min((B + s) / A, (B - s) / A);
			if (fr + hi * dr >= 0.0) t = hi;
			else if (fr + lo * dr >= 0.0) t = lo;
			else return vec4(0.0);
		}
	}
	float spread = m1.w;
	if (spread < 0.5) t = clamp(t, 0.0, 1.0);
	else if (spread < 1.5) { t = abs(t); float k = floor(t); t -= k; if (mod(k, 2.0) == 1.0) t = 1.0 - t; }
	else t = t - floor(t);
	return ramp_at(g, t);
}

void main() {
	vec2 px = floor(gl_FragCoord.xy);
	ivec2 ip = ivec2(px);
	int kind = int(vc.x);
	if (kind == 0) {
		int first = int(vd.x), n = int(vd.y);
		float acc = 0.0;
		for (int i = 0; i < n; i++) acc += edge_area(texelFetch(segs, first + i), px);
		float v = abs(acc);
		float cov;
		int rm = int(vc.z);
		if ((rm & 1) == 0) cov = min(v, 1.0);
		else { v = v - 2.0 * floor(v / 2.0); cov = v > 1.0 ? 2.0 - v : v; }
		int mode = rm >> 1;
		if (mode == 0) {
			vec4 col = va;
			int g = int(vc.w);
			if (g >= 0) col = gradient(g, gl_FragCoord.xy);
			float al = col.a * cov;
			frag = vec4(col.rgb * al, al);
		} else if (mode == 1) {
			frag = vec4(cov);
		} else {
			float c = cov * va.x;
			if (va.y > 0.5) c = 1.0 - c;
			frag = vec4(mode == 3 ? 1.0 - c : c);
		}
	} else if (kind == 1) {
		vec4 s = texelFetch(src_layer, ip, 0);
		int mk = int(va.y);
		if (mk != 0) {
			vec4 mt = texelFetch(matte_layer, ip, 0);
			float f = (mk >= 3 ? dot(mt.rgb, vec3(0.2125, 0.7154, 0.0721)) : mt.a) * va.z;
			if (mk == 2 || mk == 4) f = 1.0 - f;
			s *= f;
		}
		frag = s * va.x;
	} else {
		frag = vec4(texelFetch(src_layer, ip, 0).a);
	}
}
__END
;

HLSL_SCENE_SRC :: #string __END

struct SInst { float4 a; float4 b; float4 c; float4 d; };
StructuredBuffer<SInst> insts : register(t0);
StructuredBuffer<float4> segs : register(t1);
StructuredBuffer<float4> grads : register(t2);
StructuredBuffer<uint> ramps : register(t3); // RGBA8, r in the low byte
Texture2D src_layer : register(t4);
Texture2D matte_layer : register(t5);
cbuffer Uniforms : register(b0) { float2 viewport; uint base_instance; uint pad; };

struct SVOut {
	float4 pos : SV_Position;
	nointerpolation float4 a : A;
	nointerpolation float4 c : C;
	nointerpolation float4 d : D;
};

SVOut vs_scene(uint vid : SV_VertexID, uint iid : SV_InstanceID) {
	SInst i = insts[iid + base_instance];
	float2 corner = float2(float(vid & 1u), float(vid >> 1u));
	float2 p = lerp(i.b.xy, i.b.zw, corner);
	SVOut o;
	o.pos = float4(p / viewport * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
	o.a = i.a;
	o.c = i.c;
	o.d = i.d;
	return o;
}

float G(float u) { return u <= 0.0 ? u : (u >= 1.0 ? 0.5 : u - 0.5 * u * u); }

float right_of(float u0, float u1) {
	if (max(u0, u1) <= 0.0) return 1.0;
	if (min(u0, u1) >= 1.0) return 0.0;
	if (abs(u1 - u0) < 1e-3) return saturate(1.0 - 0.5 * (u0 + u1));
	return (G(u1) - G(u0)) / (u1 - u0);
}

float edge_area(float4 e, float2 px) {
	float2 a = e.xy, b = e.zw;
	float dir = 1.0;
	if (a.y > b.y) { float2 t = a; a = b; b = t; dir = -1.0; }
	float y0 = max(a.y, px.y), y1 = min(b.y, px.y + 1.0);
	if (y1 <= y0) return 0.0;
	float dxdy = (b.x - a.x) / (b.y - a.y);
	float x0 = a.x + (y0 - a.y) * dxdy, x1 = a.x + (y1 - a.y) * dxdy;
	return dir * (y1 - y0) * right_of(x0 - px.x, x1 - px.x);
}

float4 ramp_texel(int i) {
	uint v = ramps[i];
	return float4(v & 255u, (v >> 8) & 255u, (v >> 16) & 255u, v >> 24) / 255.0;
}

float4 ramp_at(int g, float t) {
	float x = clamp(t * 256.0 - 0.5, 0.0, 255.0);
	int i0 = int(floor(x));
	int i1 = min(i0 + 1, 255);
	return lerp(ramp_texel(g * 256 + i0), ramp_texel(g * 256 + i1), x - float(i0));
}

float4 gradient(int g, float2 p) {
	float4 m0 = grads[g * 4], m1 = grads[g * 4 + 1], pp = grads[g * 4 + 2], rr = grads[g * 4 + 3];
	float2 q = float2(m0.x * p.x + m0.z * p.y + m1.x, m0.y * p.x + m0.w * p.y + m1.y);
	float2 p0 = pp.xy, p1 = pp.zw;
	float r = rr.x, fr = rr.y;
	float t;
	if (m1.z < 0.5) {
		float2 dd = p1 - p0;
		float l2 = dot(dd, dd);
		t = l2 <= 0.0 ? 0.0 : dot(q - p0, dd) / l2;
	} else {
		float2 f = p1, cd = p0 - p1, qf = q - f;
		float dr = r - fr;
		float A = dot(cd, cd) - dr * dr;
		float B = dot(qf, cd) + fr * dr;
		float C = dot(qf, qf) - fr * fr;
		if (abs(A) < 1e-9) {
			if (abs(B) < 1e-12) return float4(0, 0, 0, 0);
			t = C / (2.0 * B);
			if (fr + t * dr < 0.0) return float4(0, 0, 0, 0);
		} else {
			float disc = B * B - A * C;
			if (disc < 0.0) return float4(0, 0, 0, 0);
			float s = sqrt(disc);
			float hi = max((B + s) / A, (B - s) / A), lo = min((B + s) / A, (B - s) / A);
			if (fr + hi * dr >= 0.0) t = hi;
			else if (fr + lo * dr >= 0.0) t = lo;
			else return float4(0, 0, 0, 0);
		}
	}
	float spread = m1.w;
	if (spread < 0.5) t = saturate(t);
	else if (spread < 1.5) { t = abs(t); float k = floor(t); t -= k; if (fmod(k, 2.0) == 1.0) t = 1.0 - t; }
	else t = t - floor(t);
	return ramp_at(g, t);
}

float4 ps_scene(SVOut i) : SV_Target {
	float2 px = floor(i.pos.xy);
	int3 ip = int3(int2(px), 0);
	int kind = int(i.c.x);
	if (kind == 0) {
		int first = int(i.d.x), n = int(i.d.y);
		float acc = 0.0;
		for (int k = 0; k < n; k++) acc += edge_area(segs[first + k], px);
		float v = abs(acc);
		float cov;
		int rm = int(i.c.z);
		if ((rm & 1) == 0) cov = min(v, 1.0);
		else { v = v - 2.0 * floor(v / 2.0); cov = v > 1.0 ? 2.0 - v : v; }
		int mode = rm >> 1;
		if (mode == 0) {
			float4 col = i.a;
			int g = int(i.c.w);
			if (g >= 0) col = gradient(g, i.pos.xy);
			float al = col.a * cov;
			return float4(col.rgb * al, al);
		}
		if (mode == 1) return float4(cov, cov, cov, cov);
		float c = cov * i.a.x;
		if (i.a.y > 0.5) c = 1.0 - c;
		if (mode == 3) c = 1.0 - c;
		return float4(c, c, c, c);
	}
	if (kind == 1) {
		float4 s = src_layer.Load(ip);
		int mk = int(i.a.y);
		if (mk != 0) {
			float4 mt = matte_layer.Load(ip);
			float f = (mk >= 3 ? dot(mt.rgb, float3(0.2125, 0.7154, 0.0721)) : mt.a) * i.a.z;
			if (mk == 2 || mk == 4) f = 1.0 - f;
			s *= f;
		}
		return s * i.a.x;
	}
	float m = src_layer.Load(ip).a;
	return float4(m, m, m, m);
}
__END
;
