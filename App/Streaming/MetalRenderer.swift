import CoreVideo
import Metal
import QuartzCore
import UIKit
import simd

/// Must match RenderUniforms in Shaders.metal
private struct RenderUniforms {
	var ndcScale: SIMD2<Float>
	var uvOrigin: SIMD2<Float>
	var uvSize: SIMD2<Float>
	var lumaSize: SIMD2<Float>
	var matrix: Int32
	var transferMode: Int32
	var bicubic: Int32
	var fullRange: Int32
}

/// Draws decoded YCbCr frames into a CAMetalLayer as soon as they arrive.
///
/// SDR uses an 8-bit BT.709 layer. HDR uses a 10-bit BT.2100 PQ layer with EDR
/// enabled, so the PS5's PQ signal goes to the display untouched and iOS
/// handles the tone mapping for the panel.
final class MetalRenderer {
	let device: MTLDevice
	private let queue: MTLCommandQueue
	private let pipelineSDR: MTLRenderPipelineState
	private let pipelineHDR: MTLRenderPipelineState
	private var textureCache: CVMetalTextureCache?

	private let lock = NSLock()
	private weak var layer: CAMetalLayer?
	private var drawableSize: CGSize = .zero
	private var hdrOutput = false
	private var displayMode: DisplayMode = .fit
	private var bicubic = true
	private var paused = false

	// Frame generation (experimental)
	private var frameGenMode: FrameGenMode = .off
	private var frameInterval: CFTimeInterval = 1.0 / 60
	private let library: MTLLibrary
	/// Video thread only
	private let customGenerator: FrameGenerator?
	/// Video thread only: loaded the first time it's picked
	private var flyHighGenerator: FlyHighGenerator?
	private var flyHighFailed = false
	/// Video thread only: the generator used for the last frame
	private var activeGenerator: FrameInterpolator?
	/// Video thread only: the last real frame, kept for the next in-between
	private var previous: (luma: CVMetalTexture, chroma: CVMetalTexture)?
	/// Drawables handed to Core Animation but not on screen yet
	private var inFlight = 0
	/// Video thread only: a coarse grid of the last new frame's luma, to spot
	/// repeats, and how many stream frames ago that frame came
	private var lastSignature: [UInt8] = []
	private var framesSinceNew = 1
	/// Video thread only: when the last new frame arrived, and whether the
	/// stream lost frames since (see `noteLostFrames`)
	private var lastNewFrameAt: CFTimeInterval = 0
	private var lostSinceNew = false
	/// Debug: the last few seconds of frames shown, for the capture button (nil when off)
	private var capture: FrameCapture?
	/// Video thread only: new real frames so far, numbering pairs in a capture
	private var realFrames = 0

	/// Frames presented (stats)
	private(set) var presentedFrames = 0
	/// Frames made by frame generation, and skipped because we were behind (stats)
	private(set) var generatedFrames = 0
	private(set) var skippedFrames = 0
	/// Repeats of the last frame dropped while generating (a 30 fps game in a 60 fps stream) (stats)
	private(set) var repeatedFrames = 0
	/// In-between frames not made because frames before the real one were lost or late (stats)
	private(set) var gapFrames = 0
	/// GPU time to make one in-between frame, smoothed (stats)
	private(set) var generateMs: Double = 0
	/// What frame generation is actually running, if it differs from what was picked (stats)
	private(set) var frameGenStatus: String?
	/// The screen's current refresh rate, from the display link (stats)
	var displayHz: Double = 0

	init?() {
		guard let device = MTLCreateSystemDefaultDevice(),
			let queue = device.makeCommandQueue(),
			let library = device.makeDefaultLibrary()
		else { return nil }
		self.device = device
		self.queue = queue
		self.library = library
		customGenerator = FrameGenerator(device: device, library: library)
		if customGenerator == nil { log.error("Frame generation shaders failed to load") }

		func pipeline(_ format: MTLPixelFormat) -> MTLRenderPipelineState? {
			let desc = MTLRenderPipelineDescriptor()
			desc.vertexFunction = library.makeFunction(name: "stream_vertex")
			desc.fragmentFunction = library.makeFunction(name: "stream_fragment")
			desc.colorAttachments[0].pixelFormat = format
			return try? device.makeRenderPipelineState(descriptor: desc)
		}
		guard let sdr = pipeline(.bgra8Unorm), let hdr = pipeline(.bgr10a2Unorm) else { return nil }
		pipelineSDR = sdr
		pipelineHDR = hdr
		CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
	}

	// MARK: - Configuration (main thread)

	func attach(_ layer: CAMetalLayer) {
		layer.device = device
		layer.framebufferOnly = true
		layer.maximumDrawableCount = 3
		layer.isOpaque = true
		layer.backgroundColor = UIColor.black.cgColor
		lock.withLock { self.layer = layer }
		applyOutputMode(to: layer)
	}

	/// Frame generation should only be on when the screen can show twice `fps`
	func configure(
		hdr: Bool, displayMode: DisplayMode, bicubic: Bool, frameGen: FrameGenMode, fps: Int, frameCapture: Bool
	) {
		let changed = lock.withLock { () -> Bool in
			let changed = self.hdrOutput != hdr
			self.hdrOutput = hdr
			self.displayMode = displayMode
			self.bicubic = bicubic
			self.frameGenMode = frameGen
			self.frameInterval = 1.0 / Double(max(fps, 1))
			if frameCapture, capture == nil {
				capture = FrameCapture(device: device)
			} else if !frameCapture {
				capture = nil
			}
			return changed
		}
		if changed, let layer = lock.withLock({ self.layer }) {
			applyOutputMode(to: layer)
		}
	}

	func setDisplayMode(_ mode: DisplayMode) {
		lock.withLock { displayMode = mode }
	}

	func setPaused(_ paused: Bool) {
		lock.withLock { self.paused = paused }
	}

	/// Saves the frame capture at the next decoded frame (see FrameCapture)
	func saveCapture(_ completion: @escaping (Result<(URL, Int), Error>) -> Void) {
		guard let capture = lock.withLock({ capture }) else {
			completion(.failure(FrameCapture.CaptureError.off))
			return
		}
		capture.requestSave(completion)
	}

	func setDrawableSize(_ size: CGSize) {
		lock.withLock {
			drawableSize = size
			layer?.drawableSize = size
		}
	}

	private func applyOutputMode(to layer: CAMetalLayer) {
		let hdr = lock.withLock { hdrOutput }
		if hdr {
			layer.pixelFormat = .bgr10a2Unorm
			layer.colorspace = CGColorSpace(name: CGColorSpace.itur_2100_PQ)
			layer.wantsExtendedDynamicRangeContent = true
			// PS5 doesn't send mastering metadata over Remote Play; typical HDR10 values
			layer.edrMetadata = CAEDRMetadata.hdr10(minLuminance: 0.005, maxLuminance: 1000, opticalOutputScale: 100)
		} else {
			layer.pixelFormat = .bgra8Unorm
			layer.colorspace = CGColorSpace(name: CGColorSpace.itur_709)
			layer.wantsExtendedDynamicRangeContent = false
			layer.edrMetadata = nil
		}
	}

	// MARK: - Rendering (decoder thread)

	/// The stream lost frames before the next one to be decoded. Video thread
	/// (decoding is synchronous, so this comes before that frame's `display`).
	func noteLostFrames() {
		lostSinceNew = true
	}

	func display(_ pixelBuffer: CVPixelBuffer) {
		lock.lock()
		let layer = self.layer
		let target = drawableSize
		let hdr = hdrOutput
		let mode = displayMode
		let bicubic = self.bicubic
		let paused = self.paused
		let frameGenMode = self.frameGenMode
		let interval = frameInterval
		let inFlight = self.inFlight
		let generateMs = self.generateMs
		let capture = self.capture
		lock.unlock()

		let generator = paused ? nil : pickGenerator(frameGenMode)
		if generator !== activeGenerator {
			previous = nil
			activeGenerator?.reset()
			activeGenerator = generator
			lastSignature = []
			framesSinceNew = 1
			lastNewFrameAt = 0
			lostSinceNew = false
			lock.withLock { self.generateMs = 0 }
		}
		if let capture {
			let name: String
			if let custom = generator as? FrameGenerator {
				name = "custom (motion map \(custom.flowFormat == .rg16Float ? "rg16Float" : "rg32Float"), level \(custom.level))"
			} else if let flyHigh = generator as? FlyHighGenerator {
				name = "flyhigh \(flyHigh.status)"
			} else {
				name = "off"
			}
			capture.frameStart(generator: name, streamFps: Int((1 / interval).rounded()))
		}
		guard !paused, let layer, target.width > 0, target.height > 0, let cache = textureCache else { return }

		let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
		let tenBit = pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
			|| pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
		let fullRange = pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
			|| pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange

		// A 30 fps game in a 60 fps stream sends every frame twice. Generating
		// between a frame and its repeat is wasted (and leaves the output
		// uneven), so while generating, repeats are dropped and the in-between
		// goes halfway between the two different frames, spread over the time
		// the game frame lasts. Up to two repeats in a row (20 fps); after that
		// the frame counts as new, so a still scene keeps updating.
		var gap = interval
		// Frames lost, or a hitch (the console or network stalled): the last
		// real frame and this one can be several game frames apart, too far
		// for the motion search, so blending them makes things vanish or
		// smear. Show only the real frame then.
		var discontinuity = false
		if generator != nil {
			let signature = Self.lumaSignature(pixelBuffer, tenBit: tenBit)
			if framesSinceNew < 3, Self.isRepeat(signature, of: lastSignature) {
				framesSinceNew += 1
				repeatedFrames += 1
				capture?.note(.repeated, pair: realFrames)
				return
			}
			gap = interval * Double(framesSinceNew)
			lastSignature = signature
			framesSinceNew = 1
			let now = CACurrentMediaTime()
			discontinuity = lostSinceNew || (lastNewFrameAt > 0 && now - lastNewFrameAt > gap * 2.5)
			lastNewFrameAt = now
			lostSinceNew = false
		}
		realFrames += 1

		guard let luma = makeTexture(pixelBuffer, plane: 0, format: tenBit ? .r16Unorm : .r8Unorm, cache: cache),
			let chroma = makeTexture(pixelBuffer, plane: 1, format: tenBit ? .rg16Unorm : .rg8Unorm, cache: cache),
			let lumaTex = CVMetalTextureGetTexture(luma),
			let chromaTex = CVMetalTextureGetTexture(chroma)
		else { return }

		// Colour metadata from the stream
		let transfer = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, nil) as? String
		let matrixKey = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil) as? String
		let framePQ = transfer == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
		let bt2020 = matrixKey == (kCVImageBufferYCbCrMatrix_ITU_R_2020 as String) || framePQ

		let transferMode: Int32 =
			switch (framePQ, hdr) {
			case (true, true), (false, false): 0
			case (false, true): 1
			case (true, false): 2
			}

		// Fit / zoom geometry
		let videoW = Float(lumaTex.width)
		let videoH = Float(lumaTex.height)
		let tw = Float(target.width)
		let th = Float(target.height)
		let fitScale = min(tw / videoW, th / videoH)
		let zoomScale = max(tw / videoW, th / videoH)
		let scale = mode == .fit ? fitScale : zoomScale
		let dw = videoW * scale
		let dh = videoH * scale
		var ndcScale = SIMD2<Float>(min(dw / tw, 1), min(dh / th, 1))
		var uvSize = SIMD2<Float>(min(tw / dw, 1), min(th / dh, 1))
		if mode == .fit { uvSize = .one } else { ndcScale = .one }
		let uvOrigin = (SIMD2<Float>.one - uvSize) * 0.5

		var uniforms = RenderUniforms(
			ndcScale: ndcScale, uvOrigin: uvOrigin, uvSize: uvSize,
			lumaSize: SIMD2(videoW, videoH),
			matrix: bt2020 ? 1 : 0, transferMode: transferMode,
			bicubic: (bicubic && scale > 1.01) ? 1 : 0, fullRange: fullRange ? 1 : 0)

		guard var commandBuffer = queue.makeCommandBuffer() else { return }

		// Frame generation: show the in-between frame now and the real one half a
		// frame later. Costs half a frame of delay, since the in-between needs
		// the newer frame.
		var generated = false
		/// The in-between frame shown, for the capture (copied in the next command buffer)
		var capturedGenerated: (seq: Int, luma: MTLTexture, chroma: MTLTexture)?
		if let generator {
			let paired = generator.push(
				luma: lumaTex, chroma: chromaTex, bt2020: bt2020, fullRange: fullRange, into: commandBuffer)
			if paired, let previous, let prevLuma = CVMetalTextureGetTexture(previous.luma),
				let prevChroma = CVMetalTextureGetTexture(previous.chroma)
			{
				// Generators step their quality down when they can't keep up
				// (e.g. the phone throttling) and back up when there's room
				if generator.adapt(generateMs: generateMs, interval: gap) {
					lock.withLock { self.generateMs = 0 }
				}
				// Two or more still waiting for the screen: we're behind, so show
				// only the real frame rather than queue up more delay
				if discontinuity {
					gapFrames += 1
					capture?.note(.gap, pair: realFrames)
				} else if inFlight >= 2 {
					skippedFrames += 1
					capture?.note(.skipped, pair: realFrames)
				} else if let drawable = layer.nextDrawable(), let outLuma = generator.outLuma,
					let outChroma = generator.outChroma
				{
					generator.interpolate(
						previous: (prevLuma, prevChroma), current: (lumaTex, chromaTex), into: commandBuffer)
					draw(luma: outLuma, chroma: outChroma, uniforms: &uniforms, to: drawable, in: commandBuffer)
					commandBuffer.addCompletedHandler { [weak self] buffer in
						_ = (previous, luma, chroma)
						let ms = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
						guard let self, ms > 0 else { return }
						self.lock.withLock { self.generateMs = self.generateMs == 0 ? ms : self.generateMs * 0.9 + ms * 0.1 }
					}
					let seq = capture?.reserve(.generated, pair: realFrames)
					if let seq { capturedGenerated = (seq, outLuma, outChroma) }
					track(drawable, captureSeq: seq, capture: capture)
					commandBuffer.present(drawable)
					commandBuffer.commit()
					generatedFrames += 1
					generated = true
					guard let next = queue.makeCommandBuffer() else { return }
					commandBuffer = next
				}
			}
			self.previous = (luma, chroma)
		}

		// Keep the CVMetalTextures alive until the GPU is done with them
		commandBuffer.addCompletedHandler { _ in
			_ = luma
			_ = chroma
		}
		// Capture copies go in this command buffer, after the in-between was
		// drawn and before the next one overwrites the generator's output
		var realSeq: Int?
		if let capture {
			if let g = capturedGenerated {
				capture.copy(
					seq: g.seq, luma: g.luma, chroma: g.chroma, bt2020: bt2020, fullRange: fullRange, into: commandBuffer)
			}
			realSeq = capture.reserve(.real, pair: realFrames)
			if let realSeq {
				capture.copy(
					seq: realSeq, luma: lumaTex, chroma: chromaTex, bt2020: bt2020, fullRange: fullRange, into: commandBuffer)
			}
		}

		guard let drawable = layer.nextDrawable() else {
			commandBuffer.commit()
			return
		}
		draw(luma: lumaTex, chroma: chromaTex, uniforms: &uniforms, to: drawable, in: commandBuffer)
		track(drawable, captureSeq: realSeq, capture: capture)
		if generated {
			// Slightly under half, so a late frame doesn't push every following one later
			commandBuffer.present(drawable, afterMinimumDuration: gap * 0.45)
		} else {
			commandBuffer.present(drawable)
		}
		commandBuffer.commit()
		presentedFrames += 1
	}

	/// Luma on a 96x54 grid (8-bit), read straight from the decoded frame
	private static func lumaSignature(_ pb: CVPixelBuffer, tenBit: Bool) -> [UInt8] {
		guard CVPixelBufferLockBaseAddress(pb, .readOnly) == kCVReturnSuccess else { return [] }
		defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
		guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return [] }
		let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0)
		let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
		let cols = 96, rows = 54
		var out = [UInt8](repeating: 0, count: cols * rows)
		for r in 0..<rows {
			let row = base.advanced(by: ((r * 2 + 1) * h / (rows * 2)) * stride)
			for c in 0..<cols {
				let x = (c * 2 + 1) * w / (cols * 2)
				// 10-bit samples sit in the top bits of 16
				out[r * cols + c] =
					tenBit ? UInt8(row.load(fromByteOffset: x * 2, as: UInt16.self) >> 8) : row.load(fromByteOffset: x, as: UInt8.self)
			}
		}
		return out
	}

	/// Same picture give or take compression noise: hardly any sample moved
	/// much. A small thing moving (a character idling) still changes a few
	/// samples by a lot, so that counts as new.
	private static func isRepeat(_ a: [UInt8], of b: [UInt8]) -> Bool {
		guard !a.isEmpty, a.count == b.count else { return false }
		var big = 0, total = 0
		for i in 0..<a.count {
			let d = abs(Int(a[i]) - Int(b[i]))
			total += d
			if d > 12 { big += 1 }
		}
		return big <= 2 && Double(total) / Double(a.count) < 1.5
	}

	/// The generator for `mode`, loading FlyHigh the first time. Falls back to
	/// the custom one if FlyHigh can't load. Video thread only.
	private func pickGenerator(_ mode: FrameGenMode) -> FrameInterpolator? {
		var status: String?
		var picked: FrameInterpolator?
		switch mode {
		case .off:
			picked = nil
		case .custom:
			picked = customGenerator
			if let customGenerator, !customGenerator.status.isEmpty { status = "quality \(customGenerator.status)" }
		case .flyHigh:
			if flyHighGenerator == nil, !flyHighFailed {
				flyHighGenerator = FlyHighGenerator(device: device, library: library)
				flyHighFailed = flyHighGenerator == nil
			}
			if let flyHighGenerator {
				picked = flyHighGenerator
				status = flyHighGenerator.status.isEmpty ? nil : "network \(flyHighGenerator.status)"
			} else {
				picked = customGenerator
				status = "flyhigh failed, using frame gen"
			}
		}
		if status != frameGenStatus { lock.withLock { frameGenStatus = status } }
		return picked
	}

	private func draw(
		luma: MTLTexture, chroma: MTLTexture, uniforms: inout RenderUniforms, to drawable: CAMetalDrawable,
		in commandBuffer: MTLCommandBuffer
	) {
		// The layer's pixel format can lag a settings change by a frame
		let pipeline = drawable.texture.pixelFormat == .bgr10a2Unorm ? pipelineHDR : pipelineSDR

		let pass = MTLRenderPassDescriptor()
		pass.colorAttachments[0].texture = drawable.texture
		pass.colorAttachments[0].loadAction = .clear
		pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
		pass.colorAttachments[0].storeAction = .store

		guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
		encoder.setRenderPipelineState(pipeline)
		encoder.setVertexBytes(&uniforms, length: MemoryLayout<RenderUniforms>.stride, index: 0)
		encoder.setFragmentBytes(&uniforms, length: MemoryLayout<RenderUniforms>.stride, index: 0)
		encoder.setFragmentTexture(luma, index: 0)
		encoder.setFragmentTexture(chroma, index: 1)
		encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
		encoder.endEncoding()
	}

	/// Counts the drawable as in flight until it reaches the screen (or is dropped)
	private func track(_ drawable: CAMetalDrawable, captureSeq: Int? = nil, capture: FrameCapture? = nil) {
		lock.withLock { inFlight += 1 }
		drawable.addPresentedHandler { [weak self] shown in
			if let captureSeq, let capture { capture.presented(seq: captureSeq, at: shown.presentedTime) }
			guard let self else { return }
			self.lock.withLock { self.inFlight -= 1 }
		}
	}

	private func makeTexture(_ pb: CVPixelBuffer, plane: Int, format: MTLPixelFormat, cache: CVMetalTextureCache) -> CVMetalTexture? {
		let w = CVPixelBufferGetWidthOfPlane(pb, plane)
		let h = CVPixelBufferGetHeightOfPlane(pb, plane)
		var texture: CVMetalTexture?
		let status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, nil, format, w, h, plane, &texture)
		return status == kCVReturnSuccess ? texture : nil
	}
}

/// UIView backed by a CAMetalLayer at the screen's native pixel density.
/// Touches act as the DualSense touchpad, except the top-right corner which
/// reveals the stream menu button.
final class StreamMetalView: UIView {
	override class var layerClass: AnyClass { CAMetalLayer.self }
	var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

	let renderer: MetalRenderer

	/// Touch down/move/up in touchpad coordinates. Screen touches use slots 10 and 11.
	var onTouch: ((ControllerInput.TouchEvent) -> Void)?
	/// A quick tap that didn't move: sent instead of `.up` so it can become a click.
	var onTap: ((Int) -> Void)?
	/// Top-right hot corner (settings)
	var onCornerTap: (() -> Void)?
	/// Top-left hot corner (PS button)
	var onLeftCornerTap: (() -> Void)?

	/// Hot corner size in points, at the top-right and top-left of the view
	static let cornerSize = CGSize(width: 140, height: 90)
	private static let tapMaxDuration: TimeInterval = 0.25
	private static let tapMaxMovement: CGFloat = 12

	private struct Tracked {
		let slot: Int
		let start: CGPoint
		let time: TimeInterval
		var moved = false
	}
	private var tracked: [ObjectIdentifier: Tracked] = [:]

	/// Ask a ProMotion screen for 120 Hz while this view is on screen
	var highRefresh = true {
		didSet { if highRefresh != oldValue { updateDisplayLink() } }
	}
	private var displayLink: CADisplayLink?

	init(renderer: MetalRenderer) {
		self.renderer = renderer
		super.init(frame: .zero)
		backgroundColor = .black
		isMultipleTouchEnabled = true
		renderer.attach(metalLayer)
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError() }

	// MARK: Refresh rate

	override func didMoveToWindow() {
		super.didMoveToWindow()
		updateDisplayLink()
	}

	/// Frames are still drawn as soon as they're decoded. The display link only
	/// keeps the panel refreshing at 120 Hz, so a new frame waits at most ~8 ms
	/// for the next refresh instead of ~17 ms. It also measures the real rate.
	private func updateDisplayLink() {
		displayLink?.invalidate()
		displayLink = nil
		renderer.displayHz = 0
		guard let window, highRefresh else { return }
		let maxFPS = Float(window.screen.maximumFramesPerSecond)
		guard maxFPS > 60 else { return }
		let link = CADisplayLink(target: self, selector: #selector(displayTick))
		link.preferredFrameRateRange = CAFrameRateRange(minimum: min(80, maxFPS), maximum: maxFPS, preferred: maxFPS)
		link.add(to: .main, forMode: .common)
		displayLink = link
		log.notice("Requesting \(Int(maxFPS)) Hz while streaming")
	}

	@objc private func displayTick(_ link: CADisplayLink) {
		let frame = link.targetTimestamp - link.timestamp
		if frame > 0 { renderer.displayHz = (1 / frame).rounded() }
	}

	override func layoutSubviews() {
		super.layoutSubviews()
		// Native scale: render at the panel's real resolution, not the UIKit point scale
		let scale = window?.screen.nativeScale ?? UIScreen.main.nativeScale
		contentScaleFactor = scale
		metalLayer.contentsScale = scale
		renderer.setDrawableSize(CGSize(width: bounds.width * scale, height: bounds.height * scale))
	}

	// MARK: Touchpad

	private var cornerRect: CGRect {
		CGRect(x: bounds.maxX - Self.cornerSize.width, y: bounds.minY, width: Self.cornerSize.width, height: Self.cornerSize.height)
	}

	private var leftCornerRect: CGRect {
		CGRect(x: bounds.minX, y: bounds.minY, width: Self.cornerSize.width, height: Self.cornerSize.height)
	}

	private func touchpadPoint(_ p: CGPoint) -> (UInt16, UInt16) {
		guard bounds.width > 0, bounds.height > 0 else { return (0, 0) }
		let nx = min(max(p.x / bounds.width, 0), 1)
		let ny = min(max(p.y / bounds.height, 0), 1)
		return (UInt16((nx * 1919).rounded()), UInt16((ny * 1079).rounded()))
	}

	override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
		for touch in touches {
			let p = touch.location(in: self)
			if cornerRect.contains(p) {
				onCornerTap?()
				continue
			}
			if leftCornerRect.contains(p) {
				onLeftCornerTap?()
				continue
			}
			let used = Set(tracked.values.map(\.slot))
			guard let slot = [10, 11].first(where: { !used.contains($0) }) else { continue }
			tracked[ObjectIdentifier(touch)] = Tracked(slot: slot, start: p, time: touch.timestamp)
			let (x, y) = touchpadPoint(p)
			onTouch?(.down(slot: slot, x: x, y: y))
		}
	}

	override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
		for touch in touches {
			let key = ObjectIdentifier(touch)
			guard var t = tracked[key] else { continue }
			let p = touch.location(in: self)
			if !t.moved, hypot(p.x - t.start.x, p.y - t.start.y) > Self.tapMaxMovement {
				t.moved = true
				tracked[key] = t
			}
			let (x, y) = touchpadPoint(p)
			onTouch?(.move(slot: t.slot, x: x, y: y))
		}
	}

	override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
		for touch in touches {
			guard let t = tracked.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
			if !t.moved, touch.timestamp - t.time <= Self.tapMaxDuration {
				onTap?(t.slot)
			} else {
				onTouch?(.up(slot: t.slot))
			}
		}
	}

	override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
		for touch in touches {
			guard let t = tracked.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
			onTouch?(.up(slot: t.slot))
		}
	}
}
