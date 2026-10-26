package gfx

// Shared math for both shader languages:
//  - quad = dst grown by softness (+1px AA margin), 4 verts as a triangle strip
//  - per-corner rounded-box SDF (pixels), coverage = clamp(0.5 - d) (1px AA)
//  - softness s > 0: coverage = 1 - smoothstep(-s, s, d)
//  - border b > 0: multiply by coverage outside the inner box (dst shrunk by b, radii - b)
//  - colors are premultiplied, bilinear across the dst rect
//  - tex kind 1: R8 coverage mask multiplies alpha; kind 2: RGBA straight, tinted by color
//  - tex kind 3: NV12 video: tex = Y (R8), tex2 = CbCr (RG8), params.w = Yuv_Matrix
//  - output premultiplied; blend One, OneMinusSrcAlpha

METAL_SHADER_SRC :: `
#include <metal_stdlib>
using namespace metal;

struct Inst {
	float4 dst;
	float4 src;
	float4 c0, c1, c2, c3;
	float4 radii;
	float4 params;
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
	float2 p = mix(p0, p1, corner);
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

fragment float4 fs_main(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]], texture2d<float> tex2 [[texture(1)]]) {
	constexpr sampler smp(coord::pixel, filter::linear, address::clamp_to_edge);
	float2 center = (in.dst.xy + in.dst.zw) * 0.5;
	float2 half_size = (in.dst.zw - in.dst.xy) * 0.5;
	float2 p = in.p - center;
	float border = in.params.x, soft = in.params.y, kind = in.params.z;

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
		float4 s = tex.sample(smp, in.uv);
		c *= float4(s.rgb * s.a, s.a);
	} else if (kind == 3.0) {
		float y = tex.sample(smp, in.uv).r;
		float2 scale2 = float2(tex2.get_width(), tex2.get_height()) / float2(tex.get_width(), tex.get_height());
		float2 cc = tex2.sample(smp, in.uv * scale2).rg;
		c *= float4(yuv_to_rgb(y, cc, in.params.w), 1.0);
	}
	return c * cov;
}
`

HLSL_SHADER_SRC :: `
struct Inst {
	float4 dst;
	float4 src;
	float4 c0, c1, c2, c3;
	float4 radii;
	float4 params;
};
StructuredBuffer<Inst> insts : register(t1);
Texture2D tex : register(t0);
Texture2D tex2 : register(t2);
SamplerState smp : register(s0);
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
	float2 p = lerp(p0, p1, corner);
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
	float border = i.params.x, soft = i.params.y, kind = i.params.z;
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
	if (kind != 0.0) {
		uint tw, th;
		tex.GetDimensions(tw, th);
		float4 s = tex.Sample(smp, i.uv / float2(tw, th));
		if (kind == 1.0) c *= s.r;
		else if (kind == 3.0) {
			float2 cc = tex2.Sample(smp, i.uv / float2(tw, th)).rg;
			c *= float4(yuv_to_rgb(s.r, cc, i.params.w), 1.0);
		}
		else c *= float4(s.rgb * s.a, s.a);
	}
	return c * cov;
}
`
