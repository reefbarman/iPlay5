// fgbench: runs the app's frame generators on the Mac's GPU with synthetic
// frames, to time them and check optimisations don't change the picture.
//
//   scripts/fgbench/run.sh [custom|flyhigh] [--save NAME | --compare NAME] [--iters N]
//
// Frames are 1920x1080 NV12 (video range): a panning textured background
// with thin lines, a block moving the other way over it, and a static HUD.
// The true halfway frame is rendered too, so the PSNR against it is a rough
// quality number (synthetic motion, so only for comparing changes).

import Foundation
import Metal

let width = 1920, height = 1080
let args = CommandLine.arguments
func arg(_ name: String) -> String? {
	guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
	return args[i + 1]
}
let which = args.count > 1 && !args[1].hasPrefix("--") ? args[1] : "flyhigh"
let iterations = Int(arg("--iters") ?? "") ?? 60
let outDir = URL(fileURLWithPath: arg("--out") ?? "build/fgbench")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// MARK: - Synthetic frames

func hash(_ x: Int, _ y: Int, _ s: Int) -> Float {
	var h = UInt32(truncatingIfNeeded: x &* 374761393 &+ y &* 668265263 &+ s &* 1442695041)
	h = (h ^ (h >> 13)) &* 1274126177
	h ^= h >> 16
	return Float(h & 0xffff) / 65535
}

func noise(_ x: Float, _ y: Float, _ s: Int) -> Float {
	let x0 = Int(floor(x)), y0 = Int(floor(y))
	let fx = x - Float(x0), fy = y - Float(y0)
	let a = hash(x0, y0, s), b = hash(x0 + 1, y0, s), c = hash(x0, y0 + 1, s), d = hash(x0 + 1, y0 + 1, s)
	return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy
}

/// Background "terrain": smooth shapes, fine texture, thin dark lines
func background(_ x: Float, _ y: Float) -> (Float, Float, Float) {
	var v = 0.45 * noise(x / 96, y / 96, 1) + 0.25 * noise(x / 24, y / 24, 2) + 0.15 * noise(x / 5, y / 5, 3)
	if Int(floor(x)).mod(97) < 2 || Int(floor(y + x * 0.1)).mod(131) < 2 { v *= 0.2 }
	return (v, 0.5 + 0.12 * (noise(x / 64, y / 64, 4) - 0.5), 0.5 + 0.12 * (noise(x / 64, y / 64, 5) - 0.5))
}

/// A sign-like block: stripes and blocky "text"
func object(_ x: Float, _ y: Float) -> (Float, Float, Float) {
	let text = hash(Int(floor(x / 6)), Int(floor(y / 10)), 7) > 0.55 ? 0.9 : 0.25
	return (Float(text), 0.42, 0.6)
}

/// Per-frame noise (in 8-bit steps), standing in for compression noise, which
/// changes every frame: `--noise 3`
let noiseLevel = Float(arg("--noise") ?? "") ?? 0

/// Frame at time t (0 = previous, 1 = current), with `noise` seeded by `seed`
func frame(_ t: Float, noise: Float = 0, seed: Int = 0) -> (luma: [UInt8], chroma: [UInt8]) {
	let bg = (Float(-23.0), Float(6.0))  // background motion per frame
	let ob = (Float(31.0), Float(-9.0))
	let ox = 700 + ob.0 * t, oy = 420 + ob.1 * t
	func sample(_ x: Float, _ y: Float) -> (Float, Float, Float) {
		if y < 60 && x < 500 { return (0.85, 0.5, 0.5) }  // HUD
		if x >= ox && x < ox + 420 && y >= oy && y < oy + 180 { return object(x - ox, y - oy) }
		return background(x - bg.0 * t, y - bg.1 * t)
	}
	var luma = [UInt8](repeating: 0, count: width * height)
	var chroma = [UInt8](repeating: 0, count: width * height / 2)
	func video(_ v: Float, _ lo: Float, _ range: Float) -> UInt8 { UInt8(max(0, min(255, lo + v * range)).rounded()) }
	for y in 0..<height {
		for x in 0..<width {
			let n = noise > 0 ? (hash(x, y, seed) + hash(x, y, seed + 1) - 1) * noise / 219 * 1.7 : 0
			luma[y * width + x] = video(sample(Float(x) + 0.5, Float(y) + 0.5).0 + n, 16, 219)
		}
	}
	for y in 0..<(height / 2) {
		for x in 0..<(width / 2) {
			let s = sample(Float(x * 2) + 1, Float(y * 2) + 1)
			chroma[(y * width / 2 + x) * 2] = video(s.1, 16, 224)
			chroma[(y * width / 2 + x) * 2 + 1] = video(s.2, 16, 224)
		}
	}
	return (luma, chroma)
}

extension Int {
	func mod(_ m: Int) -> Int { ((self % m) + m) % m }
}

// MARK: - Metal

let device = MTLCreateSystemDefaultDevice()!
let queue = device.makeCommandQueue()!
let libURL = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent(
	"fg.metallib")
let library = try! device.makeLibrary(URL: libURL)

func texture(_ format: MTLPixelFormat, _ w: Int, _ h: Int, _ bytes: [UInt8]?) -> MTLTexture {
	let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
	desc.usage = [.shaderRead, .shaderWrite]
	desc.storageMode = .shared
	let t = device.makeTexture(descriptor: desc)!
	if let bytes {
		let bpp = format == .rg8Unorm ? 2 : 1
		bytes.withUnsafeBytes {
			t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w * bpp)
		}
	}
	return t
}

func upload(_ f: (luma: [UInt8], chroma: [UInt8])) -> (luma: MTLTexture, chroma: MTLTexture) {
	(texture(.r8Unorm, width, height, f.luma), texture(.rg8Unorm, width / 2, height / 2, f.chroma))
}

/// Reads a private texture back through a shared copy
func readback(_ t: MTLTexture) -> [UInt8] {
	let copy = texture(t.pixelFormat, t.width, t.height, nil)
	let cb = queue.makeCommandBuffer()!
	let blit = cb.makeBlitCommandEncoder()!
	blit.copy(from: t, to: copy)
	blit.endEncoding()
	cb.commit()
	cb.waitUntilCompleted()
	let bpp = t.pixelFormat == .rg8Unorm ? 2 : 1
	var out = [UInt8](repeating: 0, count: t.width * t.height * bpp)
	out.withUnsafeMutableBytes {
		copy.getBytes($0.baseAddress!, bytesPerRow: t.width * bpp, from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0)
	}
	return out
}

func psnr(_ a: [UInt8], _ b: [UInt8]) -> Double {
	var se = 0.0
	for i in 0..<a.count {
		let d = Double(a[i]) - Double(b[i])
		se += d * d
	}
	let mse = se / Double(a.count)
	return mse == 0 ? 99 : 10 * log10(255 * 255 / mse)
}

func savePGM(_ bytes: [UInt8], _ w: Int, _ h: Int, _ name: String) {
	var data = Data("P5\n\(w) \(h)\n255\n".utf8)
	data.append(contentsOf: bytes)
	try? data.write(to: outDir.appendingPathComponent(name))
}

// MARK: - Run

print("device: \(device.name)")
let t0 = Date()
let a = upload(frame(0, noise: noiseLevel, seed: 100)), b = upload(frame(1, noise: noiseLevel, seed: 200))
let truth = frame(0.5)
print(String(format: "frames made in %.1f s", Date().timeIntervalSince(t0)))

let generator: FrameInterpolator
switch which {
case "custom": generator = FrameGenerator(device: device, library: library)!
default:
	let fh = FlyHighGenerator(device: device, library: library)!
	fh.level = Int(arg("--level") ?? "") ?? 0
	generator = fh
}

func gpuMs(_ cb: MTLCommandBuffer) -> Double { (cb.gpuEndTime - cb.gpuStartTime) * 1000 }

// Pairs alternate A->B and B->A, as a stream would keep moving. They're
// queued back to back so the GPU stays busy (and clocked up), and timed as a
// batch: throughput per generated frame.
var pushMs: [Double] = [], interpMs: [Double] = []
var prev = a
var step = 0
func batch(_ count: Int) -> Double {
	var buffers: [(MTLCommandBuffer, MTLCommandBuffer)] = []
	for _ in 0..<count {
		let cur = step % 2 == 0 ? b : a
		step += 1
		let cb1 = queue.makeCommandBuffer()!
		_ = generator.push(luma: cur.luma, chroma: cur.chroma, bt2020: false, fullRange: false, into: cb1)
		cb1.commit()
		let cb2 = queue.makeCommandBuffer()!
		generator.interpolate(previous: prev, current: cur, into: cb2)
		cb2.commit()
		buffers.append((cb1, cb2))
		prev = cur
	}
	buffers.last!.1.waitUntilCompleted()
	pushMs = buffers.map { gpuMs($0.0) }
	interpMs = buffers.map { gpuMs($0.1) }
	return (buffers.last!.1.gpuEndTime - buffers.first!.0.gpuStartTime) * 1000 / Double(count)
}
_ = batch(30)
let perFrame = batch(iterations)

// Final pass on A -> B, for the picture
generator.reset()
for f in [a, b] {
	let cb = queue.makeCommandBuffer()!
	_ = generator.push(luma: f.luma, chroma: f.chroma, bt2020: false, fullRange: false, into: cb)
	cb.commit()
	cb.waitUntilCompleted()
}
let cb = queue.makeCommandBuffer()!
generator.interpolate(previous: a, current: b, into: cb)
cb.commit()
cb.waitUntilCompleted()
let outY = readback(generator.outLuma!), outC = readback(generator.outChroma!)

func median(_ v: [Double]) -> Double { v.sorted()[v.count / 2] }
print(String(format: "%@: %.2f ms per frame sustained (push %.2f + interpolate %.2f, medians of %d)", which,
	perFrame, median(pushMs), median(interpMs), pushMs.count))
print(String(format: "PSNR vs true halfway frame: luma %.2f dB, chroma %.2f dB (blend of A and B: %.2f dB)",
	psnr(outY, truth.luma), psnr(outC, truth.chroma),
	psnr(zip(readback(a.luma), readback(b.luma)).map { UInt8((Int($0) + Int($1) + 1) / 2) }, truth.luma)))
savePGM(outY, width, height, "\(which)-luma.pgm")
// Error against the true frame, x4, as an image (grey = 0)
savePGM(zip(outY, truth.luma).map { UInt8(max(0, min(255, 128 + (Int($0) - Int($1)) * 4))) }, width, height,
	"\(which)-error.pgm")

if let name = arg("--save") {
	try! Data(outY + outC).write(to: outDir.appendingPathComponent("\(name).raw"))
	print("saved reference \(name)")
}
if let name = arg("--compare"), let ref = try? Data(contentsOf: outDir.appendingPathComponent("\(name).raw")) {
	let cur = outY + outC
	var maxDiff = 0, sum = 0, over2 = 0
	for (i, v) in ref.enumerated() {
		let d = abs(Int(v) - Int(cur[i]))
		maxDiff = max(maxDiff, d)
		sum += d
		if d > 2 { over2 += 1 }
	}
	print(String(format: "vs %@: max diff %d, mean %.4f, pixels off by >2: %d (%.3f%%), PSNR luma %.2f dB", name,
		maxDiff, Double(sum) / Double(cur.count), over2, Double(over2) * 100 / Double(cur.count),
		psnr(outY, Array(ref.prefix(outY.count)))))
}
