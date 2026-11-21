#include <metal_stdlib>
using namespace metal;

// Custom frame generation: makes the picture halfway between two decoded frames.
//
// 1. Each frame's luma is shrunk to 1/4 and 1/8 size.
// 2. Motion is searched on the 1/8 copy in 32 px blocks, then refined on the
//    1/4 copy in 16 px blocks and cleaned up with a median filter.
// 3. Every output pixel looks back along the motion into the previous frame and
//    forward into the current one, and blends the two. Of the nearby motion
//    vectors (and "no motion", which keeps HUDs still), the ones whose two
//    samples agree best get the most weight.
//
// Motion is stored as the half motion `d`, in full-size luma pixels: a point
// at `p` in the generated frame was at `p - d` in the previous frame and is at
// `p + d` in the current one.

// Must match FGParams in FrameGenerator.swift
struct FGParams {
	float2 lumaSize;
	float2 chromaSize;
	float2 quarterSize;
	float2 eighthSize;
	int2 coarseCount;  // 32 px blocks
	int2 fineCount;    // 16 px blocks
};

constexpr sampler fgLinear(filter::linear, address::clamp_to_edge, coord::normalized);

constant int FG_BLOCK = 4;          // block size in the shrunk images
constant int FG_COARSE_RANGE = 8;   // 1/8 px each way: up to 128 full px of motion per frame
constant float FG_FINE_BLOCK = 16.0;
constant float FG_NEWER_WEIGHT = 0.75;  // share of the newer frame in the blend

// MARK: - Shrinking

// Full luma -> 1/4 size, a 4x4 box made of four bilinear taps
kernel void fg_reduce4(texture2d<float, access::sample> src [[texture(0)]],
                       texture2d<float, access::write> dst [[texture(1)]],
                       constant FGParams &p [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]]) {
	if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
	float2 base = float2(gid) * 4.0;
	float2 inv = 1.0 / p.lumaSize;
	float s = src.sample(fgLinear, (base + float2(1, 1)) * inv).r
	        + src.sample(fgLinear, (base + float2(3, 1)) * inv).r
	        + src.sample(fgLinear, (base + float2(1, 3)) * inv).r
	        + src.sample(fgLinear, (base + float2(3, 3)) * inv).r;
	dst.write(float4(s * 0.25), gid);
}

// 1/4 -> 1/8 size
kernel void fg_reduce2(texture2d<float, access::sample> src [[texture(0)]],
                       texture2d<float, access::write> dst [[texture(1)]],
                       constant FGParams &p [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]]) {
	if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
	float2 uv = (float2(gid) * 2.0 + 1.0) / p.quarterSize;
	dst.write(float4(src.sample(fgLinear, uv).r), gid);
}

// MARK: - Motion search

static float fg_read(texture2d<float, access::read> t, int2 c) {
	c = clamp(c, int2(0), int2(t.get_width() - 1, t.get_height() - 1));
	return t.read(uint2(c)).r;
}

// Exhaustive symmetric search on the 1/8 images, one 4x4 block (+1 px border) per thread
kernel void fg_coarse(texture2d<float, access::read> prev [[texture(0)]],
                      texture2d<float, access::read> curr [[texture(1)]],
                      texture2d<float, access::write> field [[texture(2)]],
                      constant FGParams &p [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
	if (int(gid.x) >= p.coarseCount.x || int(gid.y) >= p.coarseCount.y) return;
	int2 base = int2(gid) * FG_BLOCK;

	float best = INFINITY;
	int2 bestD = int2(0);
	for (int dy = -FG_COARSE_RANGE; dy <= FG_COARSE_RANGE; dy++) {
		for (int dx = -FG_COARSE_RANGE; dx <= FG_COARSE_RANGE; dx++) {
			int2 d = int2(dx, dy);
			// Prefer small motion when the match is about as good
			float sad = 0.02 * float(abs(dx) + abs(dy));
			for (int y = -1; y <= FG_BLOCK; y++) {
				for (int x = -1; x <= FG_BLOCK; x++) {
					int2 q = base + int2(x, y);
					sad += abs(fg_read(prev, q - d) - fg_read(curr, q + d));
				}
			}
			if (sad < best) {
				best = sad;
				bestD = d;
			}
		}
	}
	field.write(float4(float2(bestD) * 8.0, 0, 0), gid);
}

// `prior` is last pair's motion for this block. Flat areas (pole and trunk
// interiors) and repeating detail (windows) match many vectors about equally,
// so without it the pick changes every frame and the edges flicker. A small
// pull towards last frame's answer keeps those picks steady.
static float fg_fine_cost(texture2d<float, access::sample> prev, texture2d<float, access::sample> curr,
                          float2 base, float2 d, float2 prior, float2 quarterSize) {
	float2 dq = d * 0.25;
	float2 inv = 1.0 / quarterSize;
	float2 dp = abs(d - prior);
	float sad = 0.002 * (abs(d.x) + abs(d.y)) + 0.006 * (dp.x + dp.y);
	for (int y = -1; y <= FG_BLOCK; y++) {
		for (int x = -1; x <= FG_BLOCK; x++) {
			float2 q = base + float2(x, y) + 0.5;
			sad += abs(prev.sample(fgLinear, (q - dq) * inv).r - curr.sample(fgLinear, (q + dq) * inv).r);
		}
	}
	return sad;
}

// 16 px blocks on the 1/4 images: pick the best of zero, last pair's vector and
// the nearby coarse vectors, then a small sub-pixel step search around it
kernel void fg_fine(texture2d<float, access::sample> prev [[texture(0)]],
                    texture2d<float, access::sample> curr [[texture(1)]],
                    texture2d<float, access::read> coarse [[texture(2)]],
                    texture2d<float, access::write> field [[texture(3)]],
                    texture2d<float, access::read> priorField [[texture(4)]],
                    constant FGParams &p [[buffer(0)]],
                    constant int &hasPrior [[buffer(1)]],
                    uint2 gid [[thread_position_in_grid]]) {
	if (int(gid.x) >= p.fineCount.x || int(gid.y) >= p.fineCount.y) return;
	float2 base = float2(gid) * float(FG_BLOCK);
	int2 cell = int2(gid) / 2;
	float2 prior = hasPrior ? priorField.read(gid).xy : float2(0);

	float2 bestD = float2(0);
	float best = fg_fine_cost(prev, curr, base, bestD, prior, p.quarterSize);
	if (hasPrior) {
		float cost = fg_fine_cost(prev, curr, base, prior, prior, p.quarterSize);
		if (cost < best) {
			best = cost;
			bestD = prior;
		}
	}
	for (int cy = -1; cy <= 1; cy++) {
		for (int cx = -1; cx <= 1; cx++) {
			int2 c = clamp(cell + int2(cx, cy), int2(0), p.coarseCount - 1);
			float2 d = coarse.read(uint2(c)).xy;
			float cost = fg_fine_cost(prev, curr, base, d, prior, p.quarterSize);
			if (cost < best) {
				best = cost;
				bestD = d;
			}
		}
	}

	// Step search: 4, 2, 1 full px (1, 1/2, 1/4 of a 1/4-size pixel)
	for (float step = 4.0; step >= 1.0; step *= 0.5) {
		float2 centre = bestD;
		const float2 dirs[4] = { float2(step, 0), float2(-step, 0), float2(0, step), float2(0, -step) };
		for (int i = 0; i < 4; i++) {
			float2 d = centre + dirs[i];
			float cost = fg_fine_cost(prev, curr, base, d, prior, p.quarterSize);
			if (cost < best) {
				best = cost;
				bestD = d;
			}
		}
	}
	field.write(float4(bestD, 0, 0), gid);
}

// 3x3 vector median: removes lone wrong vectors without blurring motion edges
kernel void fg_smooth(texture2d<float, access::read> src [[texture(0)]],
                      texture2d<float, access::write> dst [[texture(1)]],
                      constant FGParams &p [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
	if (int(gid.x) >= p.fineCount.x || int(gid.y) >= p.fineCount.y) return;
	float2 v[9];
	int n = 0;
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			int2 c = clamp(int2(gid) + int2(x, y), int2(0), p.fineCount - 1);
			v[n++] = src.read(uint2(c)).xy;
		}
	}
	float best = INFINITY;
	float2 bestV = v[4];
	for (int i = 0; i < 9; i++) {
		float dist = 0;
		for (int j = 0; j < 9; j++) {
			float2 diff = abs(v[i] - v[j]);
			dist += diff.x + diff.y;
		}
		if (dist < best) {
			best = dist;
			bestV = v[i];
		}
	}
	dst.write(float4(bestV, 0, 0), gid);
}

// MARK: - Synthesis

// Candidate weights for the pixel at full-size luma position `pos`, from the 4
// nearest block vectors plus zero motion.
//
// Thin detail (power lines, fences, text) is where this goes wrong: if the
// motion is a little off, blending the two frames gives two faint copies of a
// line, and real frames show one sharp copy, so it flickers. So:
// - each candidate is judged on a small patch, not one pixel, so the choice
//   doesn't jump around from frame to frame;
// - weights are relative to the best candidate, so the best one wins clearly
//   even when nothing matches well;
// - where the two frames disagree along a candidate, it uses the current
//   frame's pixel alone instead of a half-and-half mix.
struct FGCandidates {
	float2 d[5];
	float w[5];
	float agree[5];  // 1 where the two frames match along the candidate, 0 where they don't
	float y[5];      // luma along each candidate
	float cur[5];    // the newer frame's luma alone along each candidate
	// How well the best candidate fits, 0...1. Where nothing fits (wheels
	// spinning, things changing shape), any blend lands detail in a different
	// wrong place each frame, which flickers. There we use the newer frame
	// alone, still moved along the motion so a wheel stays on its car.
	float confidence;
};

static FGCandidates fg_candidates(texture2d<float, access::sample> prevY, texture2d<float, access::sample> currY,
                                  texture2d<float, access::read> field, float2 pos, constant FGParams &p) {
	FGCandidates c;
	float2 inv = 1.0 / p.lumaSize;
	float2 f = pos / FG_FINE_BLOCK - 0.5;
	float2 f0 = floor(f);
	float2 t = f - f0;
	int2 i0 = int2(f0);
	float cost[5];
	float bw[5];
	float minCost = INFINITY;
	for (int j = 0; j < 5; j++) {
		if (j < 4) {
			int2 o = int2(j & 1, j >> 1);
			int2 cell = clamp(i0 + o, int2(0), p.fineCount - 1);
			c.d[j] = field.read(uint2(cell)).xy;
			float2 wt = mix(1.0 - t, t, float2(o));
			bw[j] = wt.x * wt.y + 0.02;
		} else {
			// Zero motion: keeps HUDs and other static overlays in place
			c.d[j] = float2(0);
			bw[j] = 0.3;
		}
		float2 pa = pos - c.d[j];
		float2 pb = pos + c.d[j];
		float a = prevY.sample(fgLinear, pa * inv).r;
		float b = currY.sample(fgLinear, pb * inv).r;
		// Two more taps between pixels, each the average of a 2x2: covers about 3x3
		float a1 = prevY.sample(fgLinear, (pa - 0.5) * inv).r;
		float b1 = currY.sample(fgLinear, (pb - 0.5) * inv).r;
		float a2 = prevY.sample(fgLinear, (pa + 0.5) * inv).r;
		float b2 = currY.sample(fgLinear, (pb + 0.5) * inv).r;
		cost[j] = (abs(a - b) + abs(a1 - b1) + abs(a2 - b2)) * (1.0 / 3.0);
		minCost = min(minCost, cost[j]);

		c.agree[j] = exp(-abs(a - b) * 20.0);
		// Mostly the newer frame even where they agree: a 50/50 mix smooths out
		// compression noise, so generated frames look cleaner than real ones and
		// soft areas like shadows shimmer as the two alternate
		c.y[j] = mix(b, mix(a, b, FG_NEWER_WEIGHT), c.agree[j]);
		c.cur[j] = b;
	}
	for (int j = 0; j < 5; j++) {
		c.w[j] = bw[j] * exp(-(cost[j] - minCost) * 60.0) + 1e-6;
	}
	c.confidence = 1.0 - smoothstep(0.03, 0.09, minCost);
	return c;
}

kernel void fg_synth_luma(texture2d<float, access::sample> prevY [[texture(0)]],
                          texture2d<float, access::sample> currY [[texture(1)]],
                          texture2d<float, access::read> field [[texture(2)]],
                          texture2d<float, access::write> outY [[texture(3)]],
                          constant FGParams &p [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
	if (gid.x >= outY.get_width() || gid.y >= outY.get_height()) return;
	float2 pos = float2(gid) + 0.5;
	FGCandidates c = fg_candidates(prevY, currY, field, pos, p);
	float sum = 0, held = 0, wsum = 0;
	for (int j = 0; j < 5; j++) {
		sum += c.w[j] * c.y[j];
		held += c.w[j] * c.cur[j];
		wsum += c.w[j];
	}
	outY.write(float4(mix(held, sum, c.confidence) / wsum), gid);
}

kernel void fg_synth_chroma(texture2d<float, access::sample> prevY [[texture(0)]],
                            texture2d<float, access::sample> currY [[texture(1)]],
                            texture2d<float, access::sample> prevC [[texture(2)]],
                            texture2d<float, access::sample> currC [[texture(3)]],
                            texture2d<float, access::read> field [[texture(4)]],
                            texture2d<float, access::write> outC [[texture(5)]],
                            constant FGParams &p [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
	if (gid.x >= outC.get_width() || gid.y >= outC.get_height()) return;
	float2 posC = float2(gid) + 0.5;
	float2 scale = p.lumaSize / p.chromaSize;
	FGCandidates c = fg_candidates(prevY, currY, field, posC * scale, p);
	float2 inv = 1.0 / p.chromaSize;
	float2 sum = 0, held = 0;
	float wsum = 0;
	for (int j = 0; j < 5; j++) {
		float2 dc = c.d[j] / scale;
		float2 a = prevC.sample(fgLinear, (posC - dc) * inv).rg;
		float2 b = currC.sample(fgLinear, (posC + dc) * inv).rg;
		sum += c.w[j] * mix(b, mix(a, b, FG_NEWER_WEIGHT), c.agree[j]);
		held += c.w[j] * b;
		wsum += c.w[j];
	}
	outC.write(float4(mix(held, sum, c.confidence) / wsum, 0, 0), gid);
}
