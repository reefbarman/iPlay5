import Foundation
import Metal

// Must match the param structs in FlyHigh.metal
private struct FHInputParams { var oh, ow: UInt32; var matrix, fullRange: Int32 }
private struct FHInterpParams { var c, ih, iw, oh, ow, aa, c0: UInt32; var scale: Float }
private struct FHPoolParams { var c, h, w, oh, ow, k: UInt32 }
private struct FHLumaParams { var h, w, c0: UInt32; var scale: Float }
private struct FHSadParams { var h, w, radius, span: UInt32 }
private struct FHWarpParams { var c, h, w, f0, i0: UInt32; var fs, iscale: Float }
private struct FHConvexParams { var c, h, w: UInt32 }
private struct FHConvParams { var cin, cout, h, w, hout, wout, act, res: UInt32 }
private struct FHCopyParams { var c, h, w, c0: UInt32; var scale: Float }
private struct FHFilmOutParams { var h, w: UInt32; var ta, tb: Float }
private struct FHRenderParams {
	var hq, wq: UInt32
	var fsx, fsy, kr, kb: Float
	var fullRange, still: Int32
}

/// FlyHighFG frame generation: a small neural network (from the Framegen
/// browser extension by MONZikWasTaken, run by the FlyHigh engine) that
/// estimates motion between two frames and renders the one halfway between.
/// This is a Metal port of the engine's graph (models/graph.json): encoders,
/// a coarse flow net on a cost volume, `iterations` refinement passes, FiLM
/// time conditioning, convex upsampling and a residual refine net, then a
/// render that samples the decoded YCbCr planes directly.
///
/// The weights (CC BY-NC 4.0) are bundled in Resources/FlyHigh.
///
/// Used from the video thread only.
final class FlyHighGenerator {
	/// Refinement passes; the engine's default
	private static let iterations = 2
	/// Network height: the engine's 480-line rung for anything bigger
	private static let networkLines = 480

	private let device: MTLDevice
	private let pipelines: [String: MTLComputePipelineState]
	private let convs: [String: Conv]
	/// FiLM vector for t = 0.5 (the MLP depends only on t)
	private let film: MTLBuffer

	private struct Conv {
		let weights: MTLBuffer
		let bias: MTLBuffer
		let slope: MTLBuffer
		let cin: Int
		let cout: Int
		let act: UInt32
	}

	/// A tensor (or channel slice of one) in a [C][H][W] half buffer
	private struct View {
		let buffer: MTLBuffer
		let offset: Int
		let h: Int
		let w: Int
		/// Channel `c` onwards
		func at(_ c: Int) -> View { View(buffer: buffer, offset: offset + c * h * w * 2, h: h, w: w) }
	}

	/// One frame's encoder features, kept so each frame is encoded once
	private struct Features {
		var aq, e1, f8, e3, f16, i8, i16, l16: View
	}

	private struct State {
		var width: Int
		var height: Int
		var lumaFormat: MTLPixelFormat
		var chromaFormat: MTLPixelFormat
		var hq, wq: Int
		var frames: [Features]
		var cin, ch1, ch2, ch3, o: View
		var flowvis, fx, fr1, fr2, d, lumA, lumB: View
		var hm, dfilm, ftvt, wt36: View
		var up7, rx, blend, rq1, rq2, rt: View
		var outLuma: MTLTexture
		var outChroma: MTLTexture
	}
	private var state: State?
	private var current = 0
	private var hasPrevious = false
	private var bt2020 = false
	private var fullRange = false

	/// The last generated frame
	var outLuma: MTLTexture? { state?.outLuma }
	var outChroma: MTLTexture? { state?.outChroma }
	/// Network size, for the stats overlay
	var status: String { state.map { "\($0.wq * 4)x\($0.hq * 4)" } ?? "" }

	init?(device: MTLDevice, library: MTLLibrary) {
		self.device = device
		var pipelines: [String: MTLComputePipelineState] = [:]
		for name in [
			"fh_input", "fh_interp", "fh_avgpool", "fh_luma", "fh_luma_grad", "fh_sad", "fh_warp", "fh_convex",
			"fh_blendmix", "fh_conv1", "fh_conv2", "fh_chcopy", "fh_fill", "fh_addto", "fh_film", "fh_filmout",
			"fh_render_luma", "fh_render_chroma",
		] {
			guard let function = library.makeFunction(name: name),
				let pipeline = try? device.makeComputePipelineState(function: function)
			else {
				log.error("FlyHigh: couldn't make pipeline \(name)")
				return nil
			}
			pipelines[name] = pipeline
		}
		self.pipelines = pipelines

		guard let weights = Self.loadWeights() else { return nil }
		var convs: [String: Conv] = [:]
		let prelu = [
			"enc.e1", "enc.e2", "enc.e3", "enc.e4", "coarse.c1", "coarse.c2", "coarse.c3", "coarse.c4", "fine.r1",
			"fine.r2", "fine.r3", "film.h1", "film.h2", "refine.q1", "refine.q2", "refine.q3",
		]
		let plain = ["coarse.head", "fine.out", "up.w", "film.out"]
		for name in prelu {
			guard let conv = Self.makeConv(device, weights, weight: "\(name).0.weight", bias: "\(name).0.bias",
				slope: "\(name).1.weight", act: 1)
			else { return nil }
			convs[name] = conv
		}
		for name in plain + ["refine.q4"] {
			guard let conv = Self.makeConv(device, weights, weight: "\(name).weight", bias: "\(name).bias",
				slope: nil, act: name == "refine.q4" ? 2 : 0)
			else { return nil }
			convs[name] = conv
		}
		self.convs = convs

		// film_mlp at t = 0.5: relu(w1 t + b1), then w2 h + b2
		guard let w1 = weights.floats("film.film.0.weight"), let b1 = weights.floats("film.film.0.bias"),
			let w2 = weights.floats("film.film.2.weight"), let b2 = weights.floats("film.film.2.bias")
		else { return nil }
		let t: Float = 0.5
		let hidden = (0..<w1.count).map { max(0, w1[$0] * t + b1[$0]) }
		let g = (0..<b2.count).map { o in
			b2[o] + (0..<hidden.count).reduce(Float(0)) { $0 + w2[o * hidden.count + $1] * hidden[$1] }
		}
		guard let film = device.makeBuffer(bytes: g, length: g.count * 4, options: .storageModeShared) else {
			return nil
		}
		self.film = film
		log.notice("FlyHigh frame generation loaded")
	}

	func reset() {
		state = nil
		hasPrevious = false
	}

	/// Adds the newest frame and encodes its features. Returns true when
	/// there's a previous frame of the same size and format to generate from.
	func push(
		luma: MTLTexture, chroma: MTLTexture, bt2020: Bool, fullRange: Bool, into commandBuffer: MTLCommandBuffer
	) -> Bool {
		guard prepare(luma: luma, chroma: chroma), let s = state,
			let e = commandBuffer.makeComputeCommandEncoder()
		else {
			hasPrevious = false
			return false
		}
		if bt2020 != self.bt2020 || fullRange != self.fullRange { hasPrevious = false }
		self.bt2020 = bt2020
		self.fullRange = fullRange
		current ^= 1
		let f = s.frames[current]
		let (hq, wq) = (s.hq, s.wq)
		e.label = "FlyHigh: encode"

		// The network input straight at 1/4 size: the graph's interpolate(0.25, antialias)
		e.setTexture(luma, index: 0)
		e.setTexture(chroma, index: 1)
		run(e, "fh_input", [f.aq],
			FHInputParams(oh: u(hq), ow: u(wq), matrix: bt2020 ? 1 : 0, fullRange: fullRange ? 1 : 0),
			grid: (wq, hq, 1))
		run(e, "fh_avgpool", [f.aq, f.i8], FHPoolParams(c: 3, h: u(hq), w: u(wq), oh: u(hq / 2), ow: u(wq / 2), k: 2),
			grid: (wq / 2, hq / 2, 3))
		run(e, "fh_avgpool", [f.i8, f.i16],
			FHPoolParams(c: 3, h: u(hq / 2), w: u(wq / 2), oh: u(hq / 4), ow: u(wq / 4), k: 2),
			grid: (wq / 4, hq / 4, 3))
		run(e, "fh_luma", [f.i16, f.l16], FHLumaParams(h: u(hq / 4), w: u(wq / 4), c0: 0, scale: 1),
			grid: (wq / 4, hq / 4, 1))
		conv(e, "enc.e1", f.aq, stride: 2, f.e1)
		conv(e, "enc.e2", f.e1, f.f8, residual: f.e1)
		conv(e, "enc.e3", f.f8, stride: 2, f.e3)
		conv(e, "enc.e4", f.e3, f.f16, residual: f.e3)
		e.endEncoding()

		let paired = hasPrevious
		hasPrevious = true
		return paired
	}

	/// Encodes the in-between frame of the previous and current frame into `outLuma`/`outChroma`
	func interpolate(
		previous: (luma: MTLTexture, chroma: MTLTexture), current frame: (luma: MTLTexture, chroma: MTLTexture),
		into commandBuffer: MTLCommandBuffer
	) {
		guard let s = state, let e = commandBuffer.makeComputeCommandEncoder() else { return }
		let a = s.frames[current ^ 1], b = s.frames[current]
		let (hq, wq) = (s.hq, s.wq)
		let (h8, w8, h16, w16) = (hq / 2, wq / 2, hq / 4, wq / 4)
		e.label = "FlyHigh: interpolate"

		// Coarse flow at 1/16: features, images, zero side/state channels, cost volume
		copy(e, a.f16, s.cin, c: 72)
		copy(e, b.f16, s.cin.at(72), c: 72)
		copy(e, a.i16, s.cin.at(144), c: 3)
		copy(e, b.i16, s.cin.at(147), c: 3)
		fill(e, s.cin.at(150), count: 80 * h16 * w16)
		run(e, "fh_sad", [a.l16, b.l16, s.cin.at(230)], FHSadParams(h: u(h16), w: u(w16), radius: 3, span: 7),
			grid: (w16, h16, 49))
		conv(e, "coarse.c1", s.cin, s.ch1)
		conv(e, "coarse.c2", s.ch1, s.ch2)
		conv(e, "coarse.c3", s.ch2, s.ch3, residual: s.ch1)
		conv(e, "coarse.c4", s.ch3, s.ch2)
		conv(e, "coarse.head", s.ch2, s.o)
		run(e, "fh_interp", [s.o, s.flowvis],
			FHInterpParams(c: 4, ih: u(h16), iw: u(w16), oh: u(h8), ow: u(w8), aa: 0, c0: 0, scale: 16),
			grid: (w8, h8, 4))
		run(e, "fh_interp", [s.o, s.flowvis.at(4)],
			FHInterpParams(c: 3, ih: u(h16), iw: u(w16), oh: u(h8), ow: u(w8), aa: 0, c0: 4, scale: 1),
			grid: (w8, h8, 3))

		// Refinement at 1/8. fx = wa | wb | ia | ib | flow8 | h | fcv; the last
		// refine conv writes the new h straight into its slot.
		let h = s.fx.at(82)
		fill(e, h, count: 48 * h8 * w8)
		for _ in 0..<Self.iterations {
			warp(e, a.f8, s.flowvis, flow: 0, s.fx, c: 36, scale: 0.125)
			warp(e, b.f8, s.flowvis, flow: 2, s.fx.at(36), c: 36, scale: 0.125)
			warp(e, a.i8, s.flowvis, flow: 0, s.fx.at(72), c: 3, scale: 0.125)
			warp(e, b.i8, s.flowvis, flow: 2, s.fx.at(75), c: 3, scale: 0.125)
			copy(e, s.flowvis, s.fx.at(78), c: 4, scale: 0.125)
			run(e, "fh_luma", [s.fx, s.lumA], FHLumaParams(h: u(h8), w: u(w8), c0: 72, scale: 1), grid: (w8, h8, 1))
			run(e, "fh_luma", [s.fx, s.lumB], FHLumaParams(h: u(h8), w: u(w8), c0: 75, scale: 1), grid: (w8, h8, 1))
			run(e, "fh_sad", [s.lumA, s.lumB, s.fx.at(130)], FHSadParams(h: u(h8), w: u(w8), radius: 2, span: 5),
				grid: (w8, h8, 25))
			conv(e, "fine.r1", s.fx, s.fr1)
			conv(e, "fine.r2", s.fr1, s.fr2)
			conv(e, "fine.r3", s.fr2, h)
			conv(e, "fine.out", h, s.d)
			let n = UInt32(7 * h8 * w8)
			run(e, "fh_addto", [s.flowvis, s.d], n, grid: (Int(n), 1, 1))
		}

		// Time conditioning (FiLM) for t = 0.5, then convex upsampling to 1/4
		run(e, "fh_film", [h, View(buffer: film, offset: 0, h: 1, w: 1), s.hm],
			FHConvexParams(c: 48, h: u(h8), w: u(w8)), grid: (w8, h8, 48))
		conv(e, "film.h1", s.hm, s.fr1)
		conv(e, "film.h2", s.fr1, s.fr2)
		conv(e, "film.out", s.fr2, s.dfilm)
		run(e, "fh_filmout", [s.flowvis, s.dfilm, s.ftvt], FHFilmOutParams(h: u(h8), w: u(w8), ta: 1, tb: 1),
			grid: (w8, h8, 1))
		conv(e, "up.w", h, s.wt36)
		run(e, "fh_convex", [s.wt36, s.ftvt, s.up7], FHConvexParams(c: 7, h: u(h8), w: u(w8)), grid: (wq, hq, 7))

		// Refine at 1/4: rx = warped A | warped B | vis | flow / 20 | luma gradient of the blend
		warp(e, a.aq, s.up7, flow: 0, s.rx, c: 3, scale: 0.25)
		warp(e, b.aq, s.up7, flow: 2, s.rx.at(3), c: 3, scale: 0.25)
		copy(e, s.up7.at(4), s.rx.at(6), c: 3)
		copy(e, s.up7, s.rx.at(9), c: 4, scale: 0.05)
		run(e, "fh_blendmix", [s.rx, s.rx.at(3), s.up7, s.blend], FHLumaParams(h: u(hq), w: u(wq), c0: 4, scale: 1),
			grid: (wq, hq, 1))
		run(e, "fh_luma_grad", [s.blend, s.rx.at(13)], FHLumaParams(h: u(hq), w: u(wq), c0: 0, scale: 1),
			grid: (wq, hq, 1))
		conv(e, "refine.q1", s.rx, s.rq1)
		conv(e, "refine.q2", s.rq1, s.rq2)
		conv(e, "refine.q3", s.rq2, s.rq1)
		conv(e, "refine.q4", s.rq1, s.rt)

		// Render at full size, in YCbCr
		let (kr, kb): (Float, Float) = bt2020 ? (0.2627, 0.0593) : (0.2126, 0.0722)
		let params = FHRenderParams(
			hq: u(hq), wq: u(wq), fsx: Float(s.width) / Float(wq * 4), fsy: Float(s.height) / Float(hq * 4),
			kr: kr, kb: kb, fullRange: fullRange ? 1 : 0, still: 1)
		e.setTextures([previous.luma, frame.luma, s.outLuma], range: 0..<3)
		run(e, "fh_render_luma", [s.up7, s.rt], params, grid: (s.width, s.height, 1))
		e.setTextures([previous.luma, frame.luma, previous.chroma, frame.chroma, s.outChroma], range: 0..<5)
		run(e, "fh_render_chroma", [s.up7, s.rt], params, grid: (s.outChroma.width, s.outChroma.height, 1))
		e.endEncoding()
	}

	// MARK: - Encoding helpers

	private func u(_ v: Int) -> UInt32 { UInt32(v) }

	private func run<P>(
		_ e: MTLComputeCommandEncoder, _ name: String, _ views: [View], _ params: P, grid: (Int, Int, Int)
	) {
		guard let pipeline = pipelines[name] else { return }
		e.setComputePipelineState(pipeline)
		for (i, v) in views.enumerated() { e.setBuffer(v.buffer, offset: v.offset, index: i) }
		var p = params
		e.setBytes(&p, length: MemoryLayout<P>.stride, index: views.count)
		let size = MTLSize(width: grid.0, height: grid.1, depth: grid.2)
		let group =
			grid.1 == 1 && grid.2 == 1
			? MTLSize(width: min(256, pipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1)
			: MTLSize(width: 8, height: 8, depth: 1)
		e.dispatchThreads(size, threadsPerThreadgroup: group)
	}

	/// 3x3 conv of `input` (all its channels the conv takes) into `output`
	private func conv(
		_ e: MTLComputeCommandEncoder, _ name: String, _ input: View, stride: Int = 1, _ output: View,
		residual: View? = nil
	) {
		guard let c = convs[name], let pipeline = pipelines[stride == 1 ? "fh_conv1" : "fh_conv2"] else { return }
		let (hout, wout) = (input.h / stride, input.w / stride)
		e.setComputePipelineState(pipeline)
		e.setBuffer(input.buffer, offset: input.offset, index: 0)
		e.setBuffer(c.weights, offset: 0, index: 1)
		e.setBuffer(c.bias, offset: 0, index: 2)
		e.setBuffer(c.slope, offset: 0, index: 3)
		e.setBuffer(output.buffer, offset: output.offset, index: 4)
		let res = residual ?? output
		e.setBuffer(res.buffer, offset: res.offset, index: 5)
		var p = FHConvParams(
			cin: u(c.cin), cout: u(c.cout), h: u(input.h), w: u(input.w), hout: u(hout), wout: u(wout), act: c.act,
			res: residual == nil ? 0 : 1)
		e.setBytes(&p, length: MemoryLayout<FHConvParams>.stride, index: 6)
		e.dispatchThreads(
			MTLSize(width: (wout + 3) / 4, height: hout, depth: (c.cout + 7) / 8),
			threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
	}

	private func copy(_ e: MTLComputeCommandEncoder, _ src: View, _ dst: View, c: Int, scale: Float = 1) {
		run(e, "fh_chcopy", [src, dst], FHCopyParams(c: u(c), h: u(src.h), w: u(src.w), c0: 0, scale: scale),
			grid: (src.w, src.h, c))
	}

	private func fill(_ e: MTLComputeCommandEncoder, _ dst: View, count: Int) {
		run(e, "fh_fill", [dst], UInt32(count), grid: (count, 1, 1))
	}

	/// Backward warp of `c` channels of `image` by the flow in channels `flow`, `flow + 1`
	private func warp(
		_ e: MTLComputeCommandEncoder, _ image: View, _ flowTensor: View, flow: Int, _ out: View, c: Int, scale: Float
	) {
		run(e, "fh_warp", [image, flowTensor, out],
			FHWarpParams(c: u(c), h: u(image.h), w: u(image.w), f0: u(flow), i0: 0, fs: scale, iscale: 1),
			grid: (image.w, image.h, c))
	}

	// MARK: - Setup

	private func prepare(luma: MTLTexture, chroma: MTLTexture) -> Bool {
		if let s = state, s.width == luma.width, s.height == luma.height, s.lumaFormat == luma.pixelFormat,
			s.chromaFormat == chroma.pixelFormat
		{
			return true
		}
		reset()
		let width = luma.width, height = luma.height
		// Network size: multiples of 32, so the 1/16 maps are whole
		let lines = max(128, min(Self.networkLines, height) / 32 * 32)
		let columns = max(128, Int((Double(lines) * Double(width) / Double(height) / 32).rounded()) * 32)
		let hq = lines / 4, wq = columns / 4
		let (h8, w8, h16, w16) = (hq / 2, wq / 2, hq / 4, wq / 4)

		var failed = false
		func tensor(_ c: Int, _ h: Int, _ w: Int) -> View {
			guard let b = device.makeBuffer(length: max(c * h * w * 2, 16), options: .storageModePrivate) else {
				failed = true
				return View(buffer: film, offset: 0, h: h, w: w)
			}
			return View(buffer: b, offset: 0, h: h, w: w)
		}
		func features() -> Features {
			Features(
				aq: tensor(3, hq, wq), e1: tensor(36, h8, w8), f8: tensor(36, h8, w8), e3: tensor(72, h16, w16),
				f16: tensor(72, h16, w16), i8: tensor(3, h8, w8), i16: tensor(3, h16, w16), l16: tensor(1, h16, w16))
		}
		func texture(_ format: MTLPixelFormat, _ w: Int, _ h: Int) -> MTLTexture? {
			let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
			desc.usage = [.shaderRead, .shaderWrite]
			desc.storageMode = .private
			return device.makeTexture(descriptor: desc)
		}
		let frames = [features(), features()]
		let s = State(
			width: width, height: height, lumaFormat: luma.pixelFormat, chromaFormat: chroma.pixelFormat, hq: hq, wq: wq,
			frames: frames,
			cin: tensor(279, h16, w16), ch1: tensor(96, h16, w16), ch2: tensor(96, h16, w16), ch3: tensor(96, h16, w16),
			o: tensor(12, h16, w16),
			flowvis: tensor(7, h8, w8), fx: tensor(155, h8, w8), fr1: tensor(48, h8, w8), fr2: tensor(48, h8, w8),
			d: tensor(7, h8, w8), lumA: tensor(1, h8, w8), lumB: tensor(1, h8, w8),
			hm: tensor(48, h8, w8), dfilm: tensor(5, h8, w8), ftvt: tensor(7, h8, w8), wt36: tensor(36, h8, w8),
			up7: tensor(7, hq, wq), rx: tensor(14, hq, wq), blend: tensor(3, hq, wq), rq1: tensor(24, hq, wq),
			rq2: tensor(24, hq, wq), rt: tensor(3, hq, wq),
			outLuma: texture(luma.pixelFormat, width, height) ?? luma,
			outChroma: texture(chroma.pixelFormat, chroma.width, chroma.height) ?? chroma)
		guard !failed, s.outLuma !== luma, s.outChroma !== chroma else {
			log.error("FlyHigh: couldn't allocate for \(width)x\(height)")
			return false
		}
		state = s
		log.notice("FlyHigh ready for \(width)x\(height), network \(wq * 4)x\(hq * 4)")
		return true
	}

	private struct Weights {
		let blob: [UInt16]
		let tensors: [String: (shape: [Int], offset: Int)]

		func halves(_ name: String) -> (shape: [Int], values: ArraySlice<UInt16>)? {
			guard let t = tensors[name] else {
				log.error("FlyHigh: missing tensor \(name)")
				return nil
			}
			let count = t.shape.reduce(1, *)
			guard t.offset + count <= blob.count else { return nil }
			return (t.shape, blob[t.offset..<(t.offset + count)])
		}

		func floats(_ name: String) -> [Float]? {
			halves(name)?.values.map { Float(Float16(bitPattern: $0)) }
		}
	}

	private static func loadWeights() -> Weights? {
		func url(_ ext: String) -> URL? {
			Bundle.main.url(forResource: "flyhighfg", withExtension: ext)
				?? Bundle.main.url(forResource: "flyhighfg", withExtension: ext, subdirectory: "FlyHigh")
		}
		guard let binURL = url("bin"), let jsonURL = url("json"), let bin = try? Data(contentsOf: binURL),
			let json = try? Data(contentsOf: jsonURL),
			let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
			let list = root["tensors"] as? [String: [String: Any]]
		else {
			log.error("FlyHigh: couldn't load the weights")
			return nil
		}
		var tensors: [String: (shape: [Int], offset: Int)] = [:]
		for (name, t) in list {
			guard let shape = t["shape"] as? [Int], let offset = t["offset"] as? Int else { continue }
			tensors[name] = (shape, offset)
		}
		let blob = bin.withUnsafeBytes { raw in
			Array(raw.bindMemory(to: UInt16.self)).map { UInt16(littleEndian: $0) }
		}
		return Weights(blob: blob, tensors: tensors)
	}

	/// Packs a [cout][cin][3][3] conv as [cout / 8][cin][9][8] for fh_conv
	private static func makeConv(
		_ device: MTLDevice, _ weights: Weights, weight: String, bias: String, slope: String?, act: UInt32
	) -> Conv? {
		guard let tensor = weights.halves(weight), tensor.shape.count == 4, let b = weights.floats(bias) else {
			return nil
		}
		let (shape, w) = (tensor.shape, tensor.values)
		let (cout, cin) = (shape[0], shape[1])
		let groups = (cout + 7) / 8
		var packed = [UInt16](repeating: 0, count: groups * cin * 72)
		let base = w.startIndex
		for co in 0..<cout {
			for ci in 0..<cin {
				for k in 0..<9 {
					packed[((co / 8 * cin + ci) * 9 + k) * 8 + co % 8] = w[base + (co * cin + ci) * 9 + k]
				}
			}
		}
		var biasPadded = [Float](repeating: 0, count: groups * 8)
		var slopePadded = [Float](repeating: 1, count: groups * 8)
		for i in 0..<cout { biasPadded[i] = b[i] }
		if let slope {
			guard let s = weights.floats(slope) else { return nil }
			for i in 0..<cout { slopePadded[i] = s[i] }
		}
		guard
			let wb = device.makeBuffer(bytes: packed, length: packed.count * 2, options: .storageModeShared),
			let bb = device.makeBuffer(bytes: biasPadded, length: biasPadded.count * 4, options: .storageModeShared),
			let sb = device.makeBuffer(bytes: slopePadded, length: slopePadded.count * 4, options: .storageModeShared)
		else { return nil }
		return Conv(weights: wb, bias: bb, slope: sb, cin: cin, cout: cout, act: act)
	}
}
