#include <metal_stdlib>
using namespace metal;

// FlyHighFG frame generation: the non-convolution ops of the network, ported
// from the FlyHigh engine's WGSL kernels (github.com/getflyhigh/flyhigh-engine,
// Apache License 2.0). The convolutions run through MPSGraph (FlyHighGenerator.swift).
//
// Tensors are [C][H][W] half buffers, as in the engine; math is float. A "view"
// is a channel offset `c0` and a `scale` applied on read, like the engine's views.

// MARK: - Input: decoded YCbCr -> the network's BGR picture

// Must match FHInputParams in FlyHighGenerator.swift
struct FHInputParams {
	uint oh, ow;     // network size
	int matrix;      // 0 = BT.709, 1 = BT.2020
	int fullRange;
};

static float3 fh_ycbcr_to_rgb(float y, float2 c, int matrix, int fullRange) {
	if (!fullRange) {
		y = (y - 16.0 / 255.0) * (255.0 / 219.0);
		c = (c - 128.0 / 255.0) * (255.0 / 224.0);
	} else {
		c = c - 0.5;
	}
	float3 rgb = matrix == 1
		? float3(y + 1.4746 * c.y, y - 0.16455 * c.x - 0.57135 * c.y, y + 1.8814 * c.x)
		: float3(y + 1.5748 * c.y, y - 0.1873 * c.x - 0.4681 * c.y, y + 1.8556 * c.x);
	return saturate(rgb);
}

// Antialiased (triangle) downscale, as torch's F.interpolate(antialias=True) in
// interp.wgsl, of the luma and chroma planes separately, then YCbCr -> RGB.
static float2 fh_aa_sample(texture2d<float, access::read> tex, uint ox, uint oy, uint ow, uint oh) {
	float sh = float(tex.get_height()) / float(oh);
	float sw = float(tex.get_width()) / float(ow);
	float fsh = max(sh, 1.0), fsw = max(sw, 1.0);
	float cy = (float(oy) + 0.5) * sh, cx = (float(ox) + 0.5) * sw;
	int ymin = max(0, int(floor(cy - fsh + 0.5))), ymax = min(int(tex.get_height()), int(floor(cy + fsh + 0.5)));
	int xmin = max(0, int(floor(cx - fsw + 0.5))), xmax = min(int(tex.get_width()), int(floor(cx + fsw + 0.5)));
	float2 acc = 0;
	float norm = 0;
	for (int y = ymin; y < ymax; y++) {
		float wy = max(0.0, 1.0 - abs((float(y) + 0.5 - cy) / fsh));
		for (int x = xmin; x < xmax; x++) {
			float wx = max(0.0, 1.0 - abs((float(x) + 0.5 - cx) / fsw));
			float w = wx * wy;
			acc += tex.read(uint2(x, y)).xy * w;
			norm += w;
		}
	}
	return acc / norm;
}

kernel void fh_input(texture2d<float, access::read> luma [[texture(0)]],
                     texture2d<float, access::read> chroma [[texture(1)]],
                     device half *outp [[buffer(0)]],
                     constant FHInputParams &p [[buffer(1)]],
                     uint2 gid [[thread_position_in_grid]]) {
	if (gid.x >= p.ow || gid.y >= p.oh) return;
	float y = fh_aa_sample(luma, gid.x, gid.y, p.ow, p.oh).x;
	float2 c = fh_aa_sample(chroma, gid.x, gid.y, p.ow, p.oh);
	float3 rgb = fh_ycbcr_to_rgb(y, c, p.matrix, p.fullRange);
	uint plane = p.oh * p.ow, i = gid.y * p.ow + gid.x;
	// BGR, as the model was trained
	outp[i] = half(rgb.b);
	outp[plane + i] = half(rgb.g);
	outp[2 * plane + i] = half(rgb.r);
}

// MARK: - interp.wgsl

struct FHInterpParams { uint c, ih, iw, oh, ow, aa, c0; float scale; };

kernel void fh_interp(device const half *inp [[buffer(0)]],
                      device half *outp [[buffer(1)]],
                      constant FHInterpParams &p [[buffer(2)]],
                      uint3 gid [[thread_position_in_grid]]) {
	uint ox = gid.x, oy = gid.y, c = gid.z;
	if (ox >= p.ow || oy >= p.oh || c >= p.c) return;
	float sh = float(p.ih) / float(p.oh);
	float sw = float(p.iw) / float(p.ow);
	uint base = (c + p.c0) * p.ih * p.iw;
	float val;
	if (p.aa == 0) {
		float iy = (float(oy) + 0.5) * sh - 0.5;
		float ix = (float(ox) + 0.5) * sw - 0.5;
		int y0 = int(floor(iy)), x0 = int(floor(ix));
		float fy = iy - float(y0), fx = ix - float(x0);
		int y0c = clamp(y0, 0, int(p.ih) - 1), y1c = clamp(y0 + 1, 0, int(p.ih) - 1);
		int x0c = clamp(x0, 0, int(p.iw) - 1), x1c = clamp(x0 + 1, 0, int(p.iw) - 1);
		float v00 = inp[base + y0c * p.iw + x0c], v01 = inp[base + y0c * p.iw + x1c];
		float v10 = inp[base + y1c * p.iw + x0c], v11 = inp[base + y1c * p.iw + x1c];
		val = (v00 * (1.0 - fx) + v01 * fx) * (1.0 - fy) + (v10 * (1.0 - fx) + v11 * fx) * fy;
	} else {
		float fsh = max(sh, 1.0), fsw = max(sw, 1.0);
		float cy = (float(oy) + 0.5) * sh, cx = (float(ox) + 0.5) * sw;
		int ymin = max(0, int(floor(cy - fsh + 0.5))), ymax = min(int(p.ih), int(floor(cy + fsh + 0.5)));
		int xmin = max(0, int(floor(cx - fsw + 0.5))), xmax = min(int(p.iw), int(floor(cx + fsw + 0.5)));
		float acc = 0, norm = 0;
		for (int y = ymin; y < ymax; y++) {
			float wy = max(0.0, 1.0 - abs((float(y) + 0.5 - cy) / fsh));
			for (int x = xmin; x < xmax; x++) {
				float wx = max(0.0, 1.0 - abs((float(x) + 0.5 - cx) / fsw));
				float w = wx * wy;
				acc += float(inp[base + y * p.iw + x]) * w;
				norm += w;
			}
		}
		val = acc / norm;
	}
	outp[(c * p.oh + oy) * p.ow + ox] = half(val * p.scale);
}

// MARK: - avgpool.wgsl

struct FHPoolParams { uint c, h, w, oh, ow, k; };

kernel void fh_avgpool(device const half *inp [[buffer(0)]],
                       device half *outp [[buffer(1)]],
                       constant FHPoolParams &p [[buffer(2)]],
                       uint3 gid [[thread_position_in_grid]]) {
	uint ox = gid.x, oy = gid.y, c = gid.z;
	if (ox >= p.ow || oy >= p.oh || c >= p.c) return;
	float acc = 0;
	for (uint ky = 0; ky < p.k; ky++)
		for (uint kx = 0; kx < p.k; kx++)
			acc += float(inp[(c * p.h + oy * p.k + ky) * p.w + ox * p.k + kx]);
	outp[(c * p.oh + oy) * p.ow + ox] = half(acc / float(p.k * p.k));
}

// MARK: - luma.wgsl

struct FHLumaParams { uint h, w, c0; float scale; };

static float fh_lum(device const half *inp, constant FHLumaParams &p, uint y, uint x) {
	uint plane = p.h * p.w, i = p.c0 * plane + y * p.w + x;
	return (0.299 * float(inp[2 * plane + i]) + 0.587 * float(inp[plane + i]) + 0.114 * float(inp[i])) * p.scale;
}

kernel void fh_luma(device const half *inp [[buffer(0)]],
                    device half *outp [[buffer(1)]],
                    constant FHLumaParams &p [[buffer(2)]],
                    uint2 gid [[thread_position_in_grid]]) {
	if (gid.x >= p.w || gid.y >= p.h) return;
	outp[gid.y * p.w + gid.x] = half(fh_lum(inp, p, gid.y, gid.x));
}

kernel void fh_luma_grad(device const half *inp [[buffer(0)]],
                         device half *outp [[buffer(1)]],
                         constant FHLumaParams &p [[buffer(2)]],
                         uint2 gid [[thread_position_in_grid]]) {
	uint x = gid.x, y = gid.y;
	if (x >= p.w || y >= p.h) return;
	float c = fh_lum(inp, p, y, x);
	float gx = x + 1 < p.w ? fh_lum(inp, p, y, x + 1) - c : 0.0;
	float gy = y + 1 < p.h ? fh_lum(inp, p, y + 1, x) - c : 0.0;
	outp[y * p.w + x] = half(abs(gx) + abs(gy));
}

// MARK: - sad.wgsl

struct FHSadParams { uint h, w, radius, span; };

kernel void fh_sad(device const half *la [[buffer(0)]],
                   device const half *lb [[buffer(1)]],
                   device half *outp [[buffer(2)]],
                   constant FHSadParams &p [[buffer(3)]],
                   uint3 gid [[thread_position_in_grid]]) {
	uint x = gid.x, y = gid.y, c = gid.z;
	if (x >= p.w || y >= p.h || c >= p.span * p.span) return;
	int dy = int(c / p.span) - int(p.radius);
	int dx = int(c % p.span) - int(p.radius);
	int hh = int(p.h), ww = int(p.w);
	float acc = 0;
	for (int wy = -1; wy <= 1; wy++) {
		for (int wx = -1; wx <= 1; wx++) {
			int yy = int(y) + wy, xx = int(x) + wx;
			if (yy >= 0 && yy < hh && xx >= 0 && xx < ww) {
				float lav = la[yy * p.w + xx];
				int syy = clamp(yy + dy, 0, hh - 1), sxx = clamp(xx + dx, 0, ww - 1);
				acc += abs(lav - float(lb[syy * p.w + sxx]));
			}
		}
	}
	outp[(c * p.h + y) * p.w + x] = half(acc / 9.0);
}

// MARK: - warp.wgsl

struct FHWarpParams { uint c, h, w, f0, i0; float fs, is; };

kernel void fh_warp(device const half *img [[buffer(0)]],
                    device const half *flow [[buffer(1)]],
                    device half *outp [[buffer(2)]],
                    constant FHWarpParams &p [[buffer(3)]],
                    uint3 gid [[thread_position_in_grid]]) {
	uint x = gid.x, y = gid.y, c = gid.z;
	if (x >= p.w || y >= p.h || c >= p.c) return;
	uint plane = p.h * p.w;
	float fx = float(flow[(p.f0 * p.h + y) * p.w + x]) * p.fs;
	float fy = float(flow[((p.f0 + 1) * p.h + y) * p.w + x]) * p.fs;
	float gx = float(x) + fx, gy = float(y) + fy;
	int x0 = int(floor(gx)), y0 = int(floor(gy));
	float ax = gx - float(x0), ay = gy - float(y0);
	int x0c = clamp(x0, 0, int(p.w) - 1), x1c = clamp(x0 + 1, 0, int(p.w) - 1);
	int y0c = clamp(y0, 0, int(p.h) - 1), y1c = clamp(y0 + 1, 0, int(p.h) - 1);
	uint base = (c + p.i0) * plane;
	float v00 = img[base + y0c * p.w + x0c], v01 = img[base + y0c * p.w + x1c];
	float v10 = img[base + y1c * p.w + x0c], v11 = img[base + y1c * p.w + x1c];
	float top = v00 * (1.0 - ax) + v01 * ax, bot = v10 * (1.0 - ax) + v11 * ax;
	outp[c * plane + y * p.w + x] = half((top * (1.0 - ay) + bot * ay) * p.is);
}

// MARK: - convex.wgsl (2x convex upsampling)

struct FHConvexParams { uint c, h, w; };

kernel void fh_convex(device const half *wt [[buffer(0)]],
                      device const half *x [[buffer(1)]],
                      device half *outp [[buffer(2)]],
                      constant FHConvexParams &p [[buffer(3)]],
                      uint3 gid [[thread_position_in_grid]]) {
	uint ox = gid.x, oy = gid.y, co = gid.z;
	if (ox >= 2 * p.w || oy >= 2 * p.h || co >= p.c) return;
	uint ih = oy / 2, iw = ox / 2, sy = oy % 2, sx = ox % 2;
	uint plane = p.h * p.w;
	float m = -3.0e38;
	float ws[9];
	for (uint k = 0; k < 9; k++) {
		uint ch = k * 4 + sy * 2 + sx;
		float v = wt[(ch * p.h + ih) * p.w + iw];
		ws[k] = v;
		m = max(m, v);
	}
	float denom = 0;
	for (uint k = 0; k < 9; k++) {
		ws[k] = exp(ws[k] - m);
		denom += ws[k];
	}
	float acc = 0;
	for (uint k = 0; k < 9; k++) {
		int ny = int(ih) - 1 + int(k / 3), nx = int(iw) - 1 + int(k % 3);
		float xv = 0;
		if (ny >= 0 && ny < int(p.h) && nx >= 0 && nx < int(p.w)) xv = x[co * plane + ny * p.w + nx];
		acc += (ws[k] / denom) * xv;
	}
	outp[(co * 2 * p.h + oy) * 2 * p.w + ox] = half(acc);
}

// MARK: - blendmix.wgsl

kernel void fh_blendmix(device const half *wa [[buffer(0)]],
                        device const half *wb [[buffer(1)]],
                        device const half *vis [[buffer(2)]],
                        device half *outp [[buffer(3)]],
                        constant FHLumaParams &p [[buffer(4)]],
                        uint2 gid [[thread_position_in_grid]]) {
	uint x = gid.x, y = gid.y;
	if (x >= p.w || y >= p.h) return;
	uint plane = p.h * p.w, i = y * p.w + x, vb = p.c0 * plane + i;
	float a = float(vis[vb]) * p.scale, b = float(vis[vb + plane]) * p.scale, c = float(vis[vb + 2 * plane]) * p.scale;
	float m = max(a, max(b, c));
	float ea = exp(a - m), eb = exp(b - m), ec = exp(c - m);
	float s = ea + eb + ec;
	float pa = float(half((ea + 0.5 * ec) / s)), pb = float(half((eb + 0.5 * ec) / s));
	for (uint ch = 0; ch < 3; ch++) {
		uint o = ch * plane + i;
		float t1 = float(half(float(wa[o]) * pa)), t2 = float(half(float(wb[o]) * pb));
		outp[o] = half(t1 + t2);
	}
}

// MARK: - conv.wgsl: 3x3 conv, pad 1, stride S, + activation (+ residual)
//
// Each thread makes 4 neighbouring output pixels x 8 output channels, so an
// input value is read once per 8 channels and the weights (the same for the
// whole threadgroup) come from cache. Weights are packed by the Swift side as
// [cout / 8][cin][9 taps][8] halves, bias and slope as floats padded to 8.
// act: 0 = none, 1 = PReLU, 2 = affine_out (2 sigmoid - 1). `res` adds a
// tensor of the output's shape after the activation (the encoders' and the
// coarse net's skip connections).

// Must match FHConvParams in FlyHighGenerator.swift
struct FHConvParams { uint cin, cout, h, w, hout, wout, act, res; };

template <uint S>
kernel void fh_conv(device const half *inp [[buffer(0)]],
                    device const half4 *wgt [[buffer(1)]],
                    device const float4 *bias [[buffer(2)]],
                    device const float4 *slope [[buffer(3)]],
                    device half *outp [[buffer(4)]],
                    device const half *res [[buffer(5)]],
                    constant FHConvParams &p [[buffer(6)]],
                    uint3 gid [[thread_position_in_grid]]) {
	uint x0 = gid.x * 4, yo = gid.y, cog = gid.z;
	if (x0 >= p.wout || yo >= p.hout) return;
	constexpr uint NX = 3 * S + 3;
	float4 a0[4], a1[4];
	for (uint i = 0; i < 4; i++) {
		a0[i] = bias[cog * 2];
		a1[i] = bias[cog * 2 + 1];
	}
	uint plane = p.h * p.w;
	int xs = int(x0 * S) - 1;
	device const half4 *wp = wgt + cog * p.cin * 18;
	for (uint ci = 0; ci < p.cin; ci++, wp += 18) {
		device const half *ip = inp + ci * plane;
		for (uint ky = 0; ky < 3; ky++) {
			int yi = int(yo * S + ky) - 1;
			if (yi < 0 || yi >= int(p.h)) continue;
			device const half *row = ip + yi * int(p.w);
			float v[NX];
			for (uint j = 0; j < NX; j++) {
				int xi = xs + int(j);
				v[j] = (xi >= 0 && xi < int(p.w)) ? float(row[xi]) : 0.0;
			}
			for (uint kx = 0; kx < 3; kx++) {
				float4 w0 = float4(wp[(ky * 3 + kx) * 2]), w1 = float4(wp[(ky * 3 + kx) * 2 + 1]);
				for (uint px = 0; px < 4; px++) {
					float x = v[px * S + kx];
					a0[px] = fma(x, w0, a0[px]);
					a1[px] = fma(x, w1, a1[px]);
				}
			}
		}
	}
	float4 s0 = slope[cog * 2], s1 = slope[cog * 2 + 1];
	uint oplane = p.hout * p.wout;
	for (uint px = 0; px < 4; px++) {
		uint xo = x0 + px;
		if (xo >= p.wout) break;
		for (uint k = 0; k < 8; k++) {
			uint co = cog * 8 + k;
			if (co >= p.cout) break;
			float v = k < 4 ? a0[px][k] : a1[px][k - 4];
			if (p.act == 1) {
				float s = k < 4 ? s0[k] : s1[k - 4];
				v = v > 0.0 ? v : s * v;
			} else if (p.act == 2) {
				v = 2.0 / (1.0 + exp(-v)) - 1.0;
			}
			uint o = co * oplane + yo * p.wout + xo;
			if (p.res) v += float(res[o]);
			outp[o] = half(v);
		}
	}
}

template [[host_name("fh_conv1")]] [[kernel]] void fh_conv<1>(
	device const half *inp [[buffer(0)]], device const half4 *wgt [[buffer(1)]],
	device const float4 *bias [[buffer(2)]], device const float4 *slope [[buffer(3)]],
	device half *outp [[buffer(4)]], device const half *res [[buffer(5)]],
	constant FHConvParams &p [[buffer(6)]], uint3 gid [[thread_position_in_grid]]);
template [[host_name("fh_conv2")]] [[kernel]] void fh_conv<2>(
	device const half *inp [[buffer(0)]], device const half4 *wgt [[buffer(1)]],
	device const float4 *bias [[buffer(2)]], device const float4 *slope [[buffer(3)]],
	device half *outp [[buffer(4)]], device const half *res [[buffer(5)]],
	constant FHConvParams &p [[buffer(6)]], uint3 gid [[thread_position_in_grid]]);

// MARK: - Small helpers: channel copy (a scaled view), fill, accumulate

// Must match FHCopyParams in FlyHighGenerator.swift
struct FHCopyParams { uint c, h, w, c0; float scale; };

kernel void fh_chcopy(device const half *inp [[buffer(0)]],
                      device half *outp [[buffer(1)]],
                      constant FHCopyParams &p [[buffer(2)]],
                      uint3 gid [[thread_position_in_grid]]) {
	uint x = gid.x, y = gid.y, c = gid.z;
	if (x >= p.w || y >= p.h || c >= p.c) return;
	outp[(c * p.h + y) * p.w + x] = half(float(inp[((c + p.c0) * p.h + y) * p.w + x]) * p.scale);
}

kernel void fh_fill(device half *outp [[buffer(0)]],
                    constant uint &n [[buffer(1)]],
                    uint gid [[thread_position_in_grid]]) {
	if (gid < n) outp[gid] = 0;
}

kernel void fh_addto(device half *acc [[buffer(0)]],
                     device const half *d [[buffer(1)]],
                     constant uint &n [[buffer(2)]],
                     uint gid [[thread_position_in_grid]]) {
	if (gid < n) acc[gid] = half(float(acc[gid]) + float(d[gid]));
}

// MARK: - film.wgsl (FiLM modulate: h * (1 + g[c]) + g[c + C])

kernel void fh_film(device const half *hh [[buffer(0)]],
                    device const float *g [[buffer(1)]],
                    device half *outp [[buffer(2)]],
                    constant FHConvexParams &p [[buffer(3)]],
                    uint3 gid [[thread_position_in_grid]]) {
	uint x = gid.x, y = gid.y, c = gid.z;
	if (x >= p.w || y >= p.h || c >= p.c) return;
	uint i = (c * p.h + y) * p.w + x;
	outp[i] = half(float(hh[i]) * (1.0 + g[c]) + g[c + p.c]);
}

// The graph's mul_t, the FiLM deltas and the concat into flow_t | vis_t:
// flow_t = (flowA 2t, flowB 2(1 - t)) + d[0:4], vis_t = vis + (d4, -d4, 0)
struct FHFilmOutParams { uint h, w; float ta, tb; };

kernel void fh_filmout(device const half *flowvis [[buffer(0)]],
                       device const half *dfilm [[buffer(1)]],
                       device half *outp [[buffer(2)]],
                       constant FHFilmOutParams &p [[buffer(3)]],
                       uint2 gid [[thread_position_in_grid]]) {
	if (gid.x >= p.w || gid.y >= p.h) return;
	uint plane = p.h * p.w, i = gid.y * p.w + gid.x;
	for (uint c = 0; c < 4; c++) {
		float lin = float(half(float(flowvis[c * plane + i]) * (c < 2 ? p.ta : p.tb)));
		outp[c * plane + i] = half(lin + float(dfilm[c * plane + i]));
	}
	float dm = dfilm[4 * plane + i];
	outp[4 * plane + i] = half(float(flowvis[4 * plane + i]) + dm);
	outp[5 * plane + i] = half(float(flowvis[5 * plane + i]) - dm);
	outp[6 * plane + i] = flowvis[6 * plane + i];
}

// MARK: - Render (render.wgsl, written straight into YCbCr)
//
// The engine renders in RGB at full resolution, sampling the source frames
// along the flow. We sample the decoded YCbCr planes instead and write the
// output planes directly: warping and blending are linear, so blending Y and
// CbCr is the same as blending RGB. The residual R_t (RGB) is turned into a
// Y / CbCr change. Sampling is hardware bilinear, as the engine's fast render.
// The still test (on by default in the engine's hosts) uses luma only.

// Must match FHRenderParams in FlyHighGenerator.swift
struct FHRenderParams {
	uint hq, wq;      // flow / vis / R_t size (1/4 of the network)
	float fsx, fsy;   // network px -> luma px
	float kr, kb;     // luma coefficients of the matrix
	int fullRange;
	int still;
};

constexpr sampler fhLinear(filter::linear, address::clamp_to_edge, coord::normalized);

struct FHQ {
	float4 flow;   // A dx, dy, B dx, dy, in luma px
	float wa, wb;  // blend weights
	float3 r;      // residual, B G R in 0...1
};

struct FHBil {
	uint i00, i01, i10, i11;
	float fx, fy;
};

static float fh_bil(device const half *t, uint ch, uint plane, FHBil b) {
	uint o = ch * plane;
	float v00 = t[o + b.i00], v01 = t[o + b.i01], v10 = t[o + b.i10], v11 = t[o + b.i11];
	return (v00 * (1.0 - b.fx) + v01 * b.fx) * (1.0 - b.fy) + (v10 * (1.0 - b.fx) + v11 * b.fx) * b.fy;
}

// Flow, visibility and residual at luma position `pos` (pixel index space),
// bilinear from the 1/4 maps (render.wgsl's qflow / qvis / qr)
static FHQ fh_q(device const half *up7, device const half *rt, float2 pos, float2 lumaSize,
                constant FHRenderParams &p) {
	float iy = (pos.y + 0.5) * float(p.hq) / lumaSize.y - 0.5;
	float ix = (pos.x + 0.5) * float(p.wq) / lumaSize.x - 0.5;
	int qy0 = int(floor(iy)), qx0 = int(floor(ix));
	uint y0 = clamp(qy0, 0, int(p.hq) - 1), y1 = clamp(qy0 + 1, 0, int(p.hq) - 1);
	uint x0 = clamp(qx0, 0, int(p.wq) - 1), x1 = clamp(qx0 + 1, 0, int(p.wq) - 1);
	FHBil b;
	b.i00 = y0 * p.wq + x0;
	b.i01 = y0 * p.wq + x1;
	b.i10 = y1 * p.wq + x0;
	b.i11 = y1 * p.wq + x1;
	b.fx = ix - float(qx0);
	b.fy = iy - float(qy0);
	uint plane = p.hq * p.wq;
	FHQ q;
	q.flow = float4(fh_bil(up7, 0, plane, b) * p.fsx, fh_bil(up7, 1, plane, b) * p.fsy,
	                fh_bil(up7, 2, plane, b) * p.fsx, fh_bil(up7, 3, plane, b) * p.fsy);
	float v0 = fh_bil(up7, 4, plane, b), v1 = fh_bil(up7, 5, plane, b), v2 = fh_bil(up7, 6, plane, b);
	float m = max(v0, max(v1, v2));
	float e0 = exp(v0 - m), e1 = exp(v1 - m), e2 = exp(v2 - m), s = e0 + e1 + e2;
	q.wa = (e0 + 0.5 * e2) / s;
	q.wb = (e1 + 0.5 * e2) / s;
	q.r = float3(fh_bil(rt, 0, plane, b), fh_bil(rt, 1, plane, b), fh_bil(rt, 2, plane, b));
	return q;
}

// Weight of "this pixel stayed" (render.wgsl's still test), from luma
static float fh_still(texture2d<float, access::sample> aY, texture2d<float, access::sample> bY,
                      float2 pos, float2 lumaSize, float warpedA, float warpedB, float yScale) {
	float es = 0;
	for (int dy = -1; dy <= 1; dy++)
		for (int dx = -1; dx <= 1; dx++) {
			float2 uv = (pos + float2(dx, dy) + 0.5) / lumaSize;
			es += abs(aY.sample(fhLinear, uv).r - bY.sample(fhLinear, uv).r);
		}
	es = es / 9.0 * yScale;
	float ef = abs(warpedA - warpedB) * yScale;
	return clamp((ef - es) / 0.04, 0.0, 1.0) * (es < 0.03 ? 1.0 : 0.0);
}

kernel void fh_render_luma(texture2d<float, access::sample> aY [[texture(0)]],
                           texture2d<float, access::sample> bY [[texture(1)]],
                           texture2d<float, access::write> outY [[texture(2)]],
                           device const half *up7 [[buffer(0)]],
                           device const half *rt [[buffer(1)]],
                           constant FHRenderParams &p [[buffer(2)]],
                           uint2 gid [[thread_position_in_grid]]) {
	if (gid.x >= outY.get_width() || gid.y >= outY.get_height()) return;
	float2 size = float2(outY.get_width(), outY.get_height());
	float2 pos = float2(gid);
	FHQ q = fh_q(up7, rt, pos, size, p);
	float a = aY.sample(fhLinear, (pos + q.flow.xy + 0.5) / size).r;
	float b = bY.sample(fhLinear, (pos + q.flow.zw + 0.5) / size).r;
	// Texture units per 0...1 of RGB
	float yScale = p.fullRange ? 1.0 : 255.0 / 219.0;
	float dy = (p.kr * q.r.z + (1.0 - p.kr - p.kb) * q.r.y + p.kb * q.r.x) / yScale;
	float y = a * q.wa + b * q.wb + dy;
	if (p.still) {
		float w = fh_still(aY, bY, pos, size, a, b, yScale);
		float own = 0.5 * (aY.sample(fhLinear, (pos + 0.5) / size).r + bY.sample(fhLinear, (pos + 0.5) / size).r);
		y = mix(y, own, w);
	}
	float lo = p.fullRange ? 0.0 : 16.0 / 255.0, hi = p.fullRange ? 1.0 : 235.0 / 255.0;
	outY.write(float4(clamp(y, lo, hi)), gid);
}

kernel void fh_render_chroma(texture2d<float, access::sample> aY [[texture(0)]],
                             texture2d<float, access::sample> bY [[texture(1)]],
                             texture2d<float, access::sample> aC [[texture(2)]],
                             texture2d<float, access::sample> bC [[texture(3)]],
                             texture2d<float, access::write> outC [[texture(4)]],
                             device const half *up7 [[buffer(0)]],
                             device const half *rt [[buffer(1)]],
                             constant FHRenderParams &p [[buffer(2)]],
                             uint2 gid [[thread_position_in_grid]]) {
	if (gid.x >= outC.get_width() || gid.y >= outC.get_height()) return;
	float2 size = float2(aY.get_width(), aY.get_height());
	float2 csize = float2(outC.get_width(), outC.get_height());
	// This chroma sample's centre in luma pixel index space
	float2 pos = (float2(gid) + 0.5) * size / csize - 0.5;
	FHQ q = fh_q(up7, rt, pos, size, p);
	float2 a = aC.sample(fhLinear, (pos + q.flow.xy + 0.5) / size).rg;
	float2 b = bC.sample(fhLinear, (pos + q.flow.zw + 0.5) / size).rg;
	float yScale = p.fullRange ? 1.0 : 255.0 / 219.0;
	float cScale = p.fullRange ? 1.0 : 255.0 / 224.0;
	float dyRGB = p.kr * q.r.z + (1.0 - p.kr - p.kb) * q.r.y + p.kb * q.r.x;
	float2 dc = float2((q.r.x - dyRGB) / (2.0 * (1.0 - p.kb)), (q.r.z - dyRGB) / (2.0 * (1.0 - p.kr))) / cScale;
	float2 c = a * q.wa + b * q.wb + dc;
	if (p.still) {
		float ya = aY.sample(fhLinear, (pos + q.flow.xy + 0.5) / size).r;
		float yb = bY.sample(fhLinear, (pos + q.flow.zw + 0.5) / size).r;
		float w = fh_still(aY, bY, pos, size, ya, yb, yScale);
		float2 uv = (pos + 0.5) / size;
		c = mix(c, 0.5 * (aC.sample(fhLinear, uv).rg + bC.sample(fhLinear, uv).rg), w);
	}
	float lo = p.fullRange ? 0.0 : 16.0 / 255.0, hi = p.fullRange ? 1.0 : 240.0 / 255.0;
	outC.write(float4(clamp(c, lo, hi), 0, 0), gid);
}
