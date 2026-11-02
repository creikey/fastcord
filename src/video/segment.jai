// Camera background blur and replacement, on the GPU and the same on every platform. MediaPipe's selfie
// segmenter (vendor/selfie_segmenter, ops in segment_model.jai) finds the people in a 256x144 copy of the
// frame; the rest is replaced by a blurred copy (a Gaussian at an eighth of the size that leaves the
// people out, so they don't bleed into it) or by a picture. One compute kernel, KERNEL_BODY, does every
// step, one op per dispatch; segment_d3d11_windows.jai, segment_gl_linux.jai and segment_metal_darwin.jai
// run it on Direct3D 11, OpenGL 4.3 and Metal, on the capture's thread, and read the frame back for the
// encoder. The model adds 250 KB to the binary.

Background :: enum u8 { None; Blur; Image; }

// background_set: the effect for the camera's next frames (UI thread). image: a picture file for .Image.
background_set :: (mode: Background, image: string) {
	locks.guard(*seg.mu);
	seg.mode = mode;
	if seg.image != image { free(seg.image); seg.image = copy_string(image); }
}

// background_error: why the effect isn't shown (.None while it works or before it first runs).
Background_Error :: enum u8 { None; Gpu; Picture; }
background_error :: () -> Background_Error {
	locks.guard(*seg.mu);
	return ifx seg.gpu_failed then .Gpu else ifx seg.mode == .Image && seg.image == seg.bad_image then .Picture else .None;
}

#scope_module

// background_frame: src with the effect applied, into dst (both NV12, tightly packed, w x h). False when
// it's off or can't run: the caller sends src unchanged. Capture threads only.
background_frame :: (src: []u8, dst: []u8, w: int, h: int, full_range: bool) -> bool {
	locks.guard(*seg.run);
	locks.lock(*seg.mu);
	mode, path := seg.mode, copy_string(seg.image,, temp);
	locks.unlock(*seg.mu);
	if mode == .None || seg.state == .Failed || w % 4 || h % 2 || w < 16 || h < 16 || w * h > 3840 * 2160 return false; // 4K: 3.1M threads, under Direct3D's 65535 groups
	n := w * h * 3 / 2;
	if seg.state == .Unready || seg.w != w || seg.h != h || seg.full != full_range {
		if (seg.state == .Unready && !net_init()) || !cs_resize(3 * n) {
			seg.state = .Failed;
			locks.guard(*seg.mu);
			seg.gpu_failed = true;
			return false;
		}
		seg.state = .Ready;
		seg.w, seg.h, seg.full, seg.warm = w, h, full_range, false;
		free(seg.loaded);
		seg.loaded = "";
	}
	image := mode == .Image && image_ready(path, w, h, n);
	cs_write_f(0, src);

	passes: [..]Pass;
	passes.allocator = temp;
	mw, mh := SEG_TENSORS[0][1], SEG_TENSORS[0][0];
	array_add(*passes, pass(mw * mh, OP_SAMPLE, w, h, xx full_range, 0, seg.tensor[0], mw, mh));
	array_add(*passes, ..seg.net);
	mask := seg.small - mw * mh;
	array_add(*passes, pass(mw * mh, OP_MASK, seg.tensor[SEG_TENSORS.count - 1], mask, mw * mh, xx seg.warm));
	seg.warm = true;
	sw := SMALL_W;
	sh := clamp(SMALL_W * h / w, 1, SMALL_MAX_H);
	small2 := seg.small + SMALL_W * SMALL_MAX_H * 4;
	if !image {
		array_add(*passes, pass(sw * sh, OP_SAMPLE, w, h, xx full_range, 1, seg.small, sw, sh, mask, mw, mh));
		array_add(*passes, pass(sw * sh, OP_BLUR, seg.small, small2, sw, sh, BLUR_RADIUS, 0));
		array_add(*passes, pass(sw * sh, OP_BLUR, small2, seg.small, sw, sh, BLUR_RADIUS, 1));
	}
	array_add(*passes, pass(n / 4, OP_COMPOSE, w, h, 2 * n, mask, mw, mh, seg.small, sw, sh, ifx image then n else 0));
	cs_run(passes);
	return cs_read_f(2 * n, dst);
}

#load "segment_model.jai";

Seg_Op :: struct {
	kind: enum s32 { CONV; DW; TCONV; MEAN; MUL; ADD; UP2; };
	act: enum s32 { NONE; RELU; HSWISH; SIGMOID; };
	a, b, out: s32;
	k, stride: s32;
	valid: bool;
	w, bias: s32;
}

// A dispatch: the kernel's 16 parameters (p[0] the op) over n threads.
Pass :: struct {
	p: [16]s32;
	n: int;
}

pass :: (n: int, p: ..int) -> Pass {
	r := Pass.{n = n};
	for p r.p[it_index] = xx it;
	return r;
}

Kernel_Lang :: enum u8 { HLSL; GLSL; MSL; }

kernel_source :: (lang: Kernel_Lang) -> string {
	head := ifx lang == .HLSL then KERNEL_HLSL else ifx lang == .GLSL then KERNEL_GLSL else KERNEL_MSL;
	return join(head, KERNEL_BODY,, temp);
}

// Each language declares the parameters PP (16 ints), the float buffer M (weights, tensors, mask, blur
// images), the word buffer F (the frame, the picture, the result, NV12 bytes) and the thread index; BUFS
// and BUFA pass the buffers to helpers where they can't be global (Metal).
KERNEL_HLSL :: #string END
#define mix lerp
cbuffer C : register(b0) { int4 PP[4]; };
RWStructuredBuffer<float> M : register(u0);
RWStructuredBuffer<uint> F : register(u1);
#define BUFS
#define BUFA
#define KERNEL [numthreads(64, 1, 1)] void cs_main(uint3 tid_ : SV_DispatchThreadID)
#define GID int(tid_.x)
END

KERNEL_GLSL :: #string END
#version 430
layout(local_size_x = 64) in;
layout(std140, binding = 0) uniform C { ivec4 PP[4]; };
layout(std430, binding = 0) buffer BM { float M[]; };
layout(std430, binding = 1) buffer BF { uint F[]; };
#define BUFS
#define BUFA
#define KERNEL void main()
#define GID int(gl_GlobalInvocationID.x)
END

KERNEL_MSL :: #string END
#include <metal_stdlib>
using namespace metal;
#define BUFS device float* M, device uint* F,
#define BUFA M, F,
#define KERNEL kernel void cs_main(device float* M [[buffer(0)]], device uint* F [[buffer(1)]], constant int4* PP [[buffer(2)]], uint tid_ [[thread_position_in_grid]])
#define GID int(tid_)
END

// Tensors are HWC floats in M. Frame bytes come from F's words; NV12's chroma pairs are (Cb, Cr).
KERNEL_BODY :: #string END
#define P(i) PP[(i) >> 2][(i) & 3]
#define BYTE(i) float((F[(i) >> 2] >> uint(((i) & 3) * 8)) & 255u)

float act(float x, int a) {
	if (a == 1) return max(x, 0.0);
	if (a == 2) return x * clamp(x + 3.0, 0.0, 6.0) / 6.0;
	if (a == 3) return 1.0 / (1.0 + exp(-x));
	return x;
}

// Bilinear: channel ch of an image of w x h x nc floats at off, at pixel position (fx, fy) (0.0 = the
// first pixel's centre), clamped to the edges.
float bilerp(BUFS int off, int w, int h, int nc, int ch, float fx, float fy) {
	float x = clamp(fx, 0.0, float(w - 1)), y = clamp(fy, 0.0, float(h - 1));
	int x0 = int(x), y0 = int(y);
	int x1 = min(x0 + 1, w - 1), y1 = min(y0 + 1, h - 1);
	float tx = x - float(x0), ty = y - float(y0);
	float a = mix(M[off + (y0 * w + x0) * nc + ch], M[off + (y0 * w + x1) * nc + ch], tx);
	float b = mix(M[off + (y1 * w + x0) * nc + ch], M[off + (y1 * w + x1) * nc + ch], tx);
	return mix(a, b, ty);
}

KERNEL {
	int gid = GID;
	int op = P(0);
	if (op == 1) {
		// Convolution, SAME or VALID by the padding given: input P1 (P2 x P3 x P4), output P5 (P6 x P7 x P8),
		// kernel P9, stride P10, padding P11 above and P12 left, weights P13 (OHWI, or HWC when P15:
		// depthwise) then biases, activation P14.
		int oc = P(8), ow = P(7), c = P(4), k = P(9);
		if (gid >= P(6) * ow * oc) return;
		int o = gid % oc, x = (gid / oc) % ow, y = gid / (oc * ow);
		bool dw = P(15) != 0;
		float s = M[P(13) + (dw ? k * k * c : oc * k * k * c) + o];
		for (int ky = 0; ky < k; ky++) {
			int iy = y * P(10) - P(11) + ky;
			if (iy < 0 || iy >= P(2)) continue;
			for (int kx = 0; kx < k; kx++) {
				int ix = x * P(10) - P(12) + kx;
				if (ix < 0 || ix >= P(3)) continue;
				int ib = P(1) + (iy * P(3) + ix) * c;
				if (dw) {
					s += M[ib + o] * M[P(13) + (ky * k + kx) * c + o];
				} else {
					int wb = P(13) + ((o * k + ky) * k + kx) * c;
					for (int i = 0; i < c; i++) s += M[ib + i] * M[wb + i];
				}
			}
		}
		M[P(5) + gid] = act(s, P(14));
	} else if (op == 2) {
		// Transposed 2x2 convolution, stride 2, to one channel: input P1 (P2 x P3 x P4), output P5, weights
		// P13 then the bias, activation P14.
		int w2 = 2 * P(3), c = P(4);
		if (gid >= 2 * P(2) * w2) return;
		int x = gid % w2, y = gid / w2;
		int ib = P(1) + ((y / 2) * P(3) + x / 2) * c, wb = P(13) + ((y % 2) * 2 + x % 2) * c;
		float s = M[P(13) + 4 * c];
		for (int i = 0; i < c; i++) s += M[ib + i] * M[wb + i];
		M[P(5) + gid] = act(s, P(14));
	} else if (op == 3) {
		// Mean over P2 pixels of P4 channels at P1, to P5.
		if (gid >= P(4)) return;
		float s = 0.0;
		for (int i = 0; i < P(2); i++) s += M[P(1) + i * P(4) + gid];
		M[P(5) + gid] = s / float(P(2));
	} else if (op == 4 || op == 5) {
		// Multiply (4) or add (5) P1 and P2 (one pixel of P4 channels when P6) over P3 floats, to P5.
		if (gid >= P(3)) return;
		float b = M[P(2) + (P(6) != 0 ? gid % P(4) : gid)];
		M[P(5) + gid] = op == 4 ? M[P(1) + gid] * b : M[P(1) + gid] + b;
	} else if (op == 6) {
		// Twice the size, bilinear with half-pixel centres: P1 (P2 x P3 x P4) to P5.
		int c = P(4), w2 = 2 * P(3);
		if (gid >= 2 * P(2) * w2 * c) return;
		int ch = gid % c, x = (gid / c) % w2, y = gid / (c * w2);
		M[P(5) + gid] = bilerp(BUFA P(1), P(3), P(2), c, ch, float(x) * 0.5 - 0.25, float(y) * 0.5 - 0.25);
	} else if (op == 7) {
		// The frame (P1 x P2 at F's start, full range when P3) averaged down to P6 x P7 at P5: RGB in
		// [0, 1] for the model (P4 0), or for the blur (P4 1) Y, Cb, Cr and a weight, each times the
		// weight, which is low where the mask (P8, P9 x P10) has a person.
		if (gid >= P(6) * P(7)) return;
		int fw = P(1), fh = P(2), x = gid % P(6), y = gid / P(6);
		float Y = 0.0, U = 0.0, V = 0.0;
		for (int j = 0; j < 4; j++) {
			int sy = min(((y * 4 + j) * 2 + 1) * fh / (P(7) * 8), fh - 1);
			for (int i = 0; i < 4; i++) {
				int sx = min(((x * 4 + i) * 2 + 1) * fw / (P(6) * 8), fw - 1);
				int uv = fw * fh + (sy / 2) * fw + (sx / 2) * 2;
				Y += BYTE(sy * fw + sx);
				U += BYTE(uv);
				V += BYTE(uv + 1);
			}
		}
		Y /= 16.0 * 255.0; U = U / (16.0 * 255.0) - 0.5; V = V / (16.0 * 255.0) - 0.5;
		int o = P(5) + gid * (3 + P(4));
		if (P(4) != 0) {
			float m = bilerp(BUFA P(8), P(9), P(10), 1, 0, (float(x) + 0.5) * float(P(9)) / float(P(6)) - 0.5, (float(y) + 0.5) * float(P(10)) / float(P(7)) - 0.5);
			float wt = (1.0 - m) * (1.0 - m) + 0.0001;
			M[o] = Y * wt; M[o + 1] = U * wt; M[o + 2] = V * wt; M[o + 3] = wt;
			return;
		}
		if (P(3) == 0) { Y = (Y - 16.0 / 255.0) * (255.0 / 219.0); U *= 255.0 / 224.0; V *= 255.0 / 224.0; }
		M[o] = clamp(Y + 1.402 * V, 0.0, 1.0);
		M[o + 1] = clamp(Y - 0.344136 * U - 0.714136 * V, 0.0, 1.0);
		M[o + 2] = clamp(Y + 1.772 * U, 0.0, 1.0);
	} else if (op == 8) {
		// The mask: the model's output P1 over P3 pixels into P2, mixed with the last frame's when P4.
		if (gid >= P(3)) return;
		float m = M[P(1) + gid];
		M[P(2) + gid] = P(4) != 0 ? mix(M[P(2) + gid], m, 0.7) : m;
	} else if (op == 9) {
		// Gaussian along x (P6 0) or y (P6 1), radius P5, of the P3 x P4 x 4 image P1, to P2.
		if (gid >= P(3) * P(4)) return;
		int x = gid % P(3), y = gid / P(3), r = P(5);
		float a0 = 0.0, a1 = 0.0, a2 = 0.0, a3 = 0.0, ws = 0.0;
		for (int d = -r; d <= r; d++) {
			int sx = P(6) != 0 ? x : clamp(x + d, 0, P(3) - 1);
			int sy = P(6) != 0 ? clamp(y + d, 0, P(4) - 1) : y;
			float g = exp(-2.0 * float(d * d) / float(r * r));
			int i = P(1) + (sy * P(3) + sx) * 4;
			a0 += M[i] * g; a1 += M[i + 1] * g; a2 += M[i + 2] * g; a3 += M[i + 3] * g; ws += g;
		}
		int o = P(2) + gid * 4;
		M[o] = a0 / ws; M[o + 1] = a1 / ws; M[o + 2] = a2 / ws; M[o + 3] = a3 / ws;
	} else if (op == 10) {
		// The result, four NV12 bytes per thread to F at byte P3: the frame (P1 x P2) where the mask (P4,
		// P5 x P6) has a person, else the picture at byte P10, or (P10 0) the blur (P7, P8 x P9 x 4).
		int fw = P(1), fh = P(2), n = fw * fh;
		if (gid * 4 >= n + n / 2) return;
		uint word = 0u;
		for (int j = 0; j < 4; j++) {
			int b = gid * 4 + j;
			bool luma = b < n;
			int c = luma ? 0 : 1 + ((b - n) & 1);
			float cx = luma ? float(b % fw) + 0.5 : float(((b - n) % fw) / 2 * 2) + 1.0;
			float cy = luma ? float(b / fw) + 0.5 : float((b - n) / fw * 2) + 1.0;
			float k = bilerp(BUFA P(4), P(5), P(6), 1, 0, cx * float(P(5)) / float(fw) - 0.5, cy * float(P(6)) / float(fh) - 0.5);
			k = smoothstep(0.3, 0.7, k);
			float bg;
			if (P(10) != 0) {
				bg = BYTE(P(10) + b);
			} else {
				float sx = cx * float(P(8)) / float(fw) - 0.5, sy = cy * float(P(9)) / float(fh) - 0.5;
				bg = bilerp(BUFA P(7), P(8), P(9), 4, c, sx, sy) / bilerp(BUFA P(7), P(8), P(9), 4, 3, sx, sy) * 255.0 + (c == 0 ? 0.0 : 128.0);
			}
			float v = mix(bg, BYTE(b), k);
			word |= uint(clamp(v + 0.5, 0.0, 255.0)) << uint(j * 8);
		}
		F[(P(3) >> 2) + gid] = word;
	}
}
END

#scope_file

SMALL_W :: 160; // the blur's width: an eighth of 1280
SMALL_MAX_H :: 320;
BLUR_RADIUS :: 9; // in SMALL_W pixels; sigma is half

SEG_MODEL :: #run,host -> string { #import "Basic"; #import "File"; return read_entire_file(tprint("%/../../vendor/selfie_segmenter/selfie_segmenter_landscape.tflite", #filepath)); };

OP_CONV :: 1;
OP_TCONV :: 2;
OP_MEAN :: 3;
OP_MUL :: 4;
OP_ADD :: 5;
OP_UP2 :: 6;
OP_SAMPLE :: 7;
OP_MASK :: 8;
OP_BLUR :: 9;
OP_COMPOSE :: 10;

seg: struct {
	mu: locks.Mutex; // mode, image, gpu_failed, bad_image: the UI's, held only briefly
	mode: Background;
	image: string; // heap
	gpu_failed: bool;
	bad_image: string; // heap: a picture that wouldn't open
	run: locks.Mutex; // the rest: capture threads, while a frame runs
	state: enum u8 { Unready; Ready; Failed; };
	net: [..]Pass; // the model's dispatches, made once
	tensor: [SEG_TENSORS.count]s32; // each tensor's first float in M
	small: s32; // the mask, then two blur images of SMALL_W x SMALL_MAX_H x 4 floats
	w, h: int;
	full, warm: bool; // warm: the mask has a previous frame to smooth with
	loaded: string; // the picture last put in F at w x h (heap), or tried: loaded_ok
	loaded_ok: bool;
};

// net_init lays out M (weights, tensors, mask, blur images), uploads the weights and makes the net's passes.
net_init :: () -> bool {
	weights: [..]float32;
	weights.allocator = temp;
	add :: (weights: *[..]float32, at: s32, count: int) -> s32 {
		first := weights.count;
		for 0..count - 1 {
			h := (cast(*u16) (SEG_MODEL.data + at))[it];
			e := cast(u32) (h >> 10) & 31;
			bits := (cast(u32) (h & 0x8000)) << 16;
			if e bits |= ((e + 112) << 23) | ((cast(u32) (h & 1023)) << 13); // normal (no model weight is subnormal, inf or NaN)
			array_add(weights, (cast(*float32) *bits).*);
		}
		return xx first;
	}
	array_reset(*seg.net);
	ops: [SEG_OPS.count][2]s32;
	for op, i: SEG_OPS {
		in, out := SEG_TENSORS[op.a], SEG_TENSORS[op.out];
		n := ifx op.kind == .CONV then out[2] * op.k * op.k * in[2] else ifx op.kind == .TCONV then 4 * in[2] else op.k * op.k * in[2];
		if op.kind == .CONV || op.kind == .DW || op.kind == .TCONV {
			ops[i][0] = add(*weights, op.w, n);
			add(*weights, op.bias, out[2]);
		}
	}
	at: s32 = xx weights.count;
	for SEG_TENSORS { seg.tensor[it_index] = at; at += it[0] * it[1] * it[2]; }
	at += SEG_TENSORS[0][0] * SEG_TENSORS[0][1];
	seg.small = at;
	if !cs_init(at + 2 * SMALL_W * SMALL_MAX_H * 4) return false;
	cs_write_m(0, weights);

	for op, i: SEG_OPS {
		in, out := SEG_TENSORS[op.a], SEG_TENSORS[op.out];
		a, o := seg.tensor[op.a], seg.tensor[op.out];
		n := out[0] * out[1] * out[2];
		p: Pass;
		if op.kind == {
			case .CONV; #through;
			case .DW;
				pad_y := ifx op.valid then 0 else max((out[0] - 1) * op.stride + op.k - in[0], 0) / 2;
				pad_x := ifx op.valid then 0 else max((out[1] - 1) * op.stride + op.k - in[1], 0) / 2;
				p = pass(n, OP_CONV, a, in[0], in[1], in[2], o, out[0], out[1], out[2], op.k, op.stride, pad_y, pad_x, ops[i][0], xx op.act, xx (op.kind == .DW));
			case .TCONV;
				p = pass(n, OP_TCONV, a, in[0], in[1], in[2], o, 0, 0, 0, 0, 0, 0, 0, ops[i][0], xx op.act);
			case .MEAN;
				p = pass(in[2], OP_MEAN, a, in[0] * in[1], 0, in[2], o);
			case .MUL; #through;
			case .ADD;
				b := SEG_TENSORS[op.b];
				p = pass(n, ifx op.kind == .MUL then OP_MUL else OP_ADD, a, seg.tensor[op.b], n, out[2], o, xx (b[0] * b[1] == 1));
			case .UP2;
				p = pass(n, OP_UP2, a, in[0], in[1], in[2], o);
		}
		array_add(*seg.net, p);
	}
	return true;
}

// image_ready puts the chosen picture into F (after the frame), scaled to cover w x h; false when there's
// none or it won't open, so the frame is blurred instead.
image_ready :: (path: string, w: int, h: int, n: int) -> bool {
	if path == "" return false;
	if seg.loaded == path return seg.loaded_ok;
	free(seg.loaded);
	seg.loaded = copy_string(path);
	data, ok := read_entire_file(path,, temp);
	img, err := imagefmt.decode_first_frame(cast([]u8) data, temp, 16 << 20);
	seg.loaded_ok = ok && err == .None;
	if !seg.loaded_ok {
		locks.guard(*seg.mu);
		free(seg.bad_image);
		seg.bad_image = copy_string(path);
		return false;
	}
	px := img.frames[0].pixels;
	nv := NewArray(n, u8,, temp);
	scale := max(cast(float) w / cast(float) img.width, cast(float) h / cast(float) img.height);
	ox, oy := (img.width - w / scale) / 2, (img.height - h / scale) / 2;
	for y: 0..h - 1 for x: 0..w - 1 {
		sx := clamp(cast(int) (ox + (x + 0.5) / scale), 0, img.width - 1);
		sy := clamp(cast(int) (oy + (y + 0.5) / scale), 0, img.height - 1);
		p := px.data + (sy * img.width + sx) * 4;
		r, g, b := cast(float) p[0], cast(float) p[1], cast(float) p[2];
		luma := 0.299 * r + 0.587 * g + 0.114 * b;
		nv[y * w + x] = cast(u8) ifx seg.full then luma + 0.5 else luma * 219 / 255 + 16.5;
		if (x | y) & 1 continue;
		u, v := (b - luma) / 1.772, (r - luma) / 1.402;
		k := ifx seg.full then 1.0 else 224.0 / 255;
		nv[w * h + (y / 2) * w + x] = cast(u8) clamp(u * k + 128.5, 0, 255);
		nv[w * h + (y / 2) * w + x + 1] = cast(u8) clamp(v * k + 128.5, 0, 255);
	}
	cs_write_f(n, nv);
	return true;
}
