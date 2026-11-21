// `--replay CAPTURE_DIR`: runs a generator on the real frames of a frame
// capture from the phone (the stream's debug capture button), so quality
// changes can be checked against actual game footage.
//
//   scripts/fgbench/run.sh custom --replay CAPTURE_DIR [--name NAME] [--from SEQ] [--to SEQ]
//
// Two things come out:
// - build/fgbench/replay-NAME: a capture folder (same format as the phone's)
//   with the real frames and this build's generated frames in between, for
//   scripts/fgcapture/run.sh. It's compared with the phone's generated frames,
//   which only match while the shader is unchanged.
// - A score from leaving real frames out: generate between real frames k-1 and
//   k+1 and compare with real frame k. Motion is twice as big as normal, so
//   it's harsher than the real thing, but it has a right answer. "detail" is
//   the error on pixels with strong edges in the real frame (text, icons,
//   poles, lines), which is where things go missing.

import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

private struct CaptureFrame {
	let seq: Int
	let kind: String
	let pair: Int
	let file: String?
}

private struct Capture {
	let dir: URL
	let manifest: [String: Any]
	let width: Int, height: Int, chromaWidth: Int, chromaHeight: Int, bytesPerSample: Int
	let fullRange: Bool, bt2020: Bool
	let frames: [CaptureFrame]

	init(_ path: String) {
		dir = URL(fileURLWithPath: path)
		guard let data = try? Data(contentsOf: dir.appendingPathComponent("frames.json")),
			let m = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			let w = m["width"] as? Int, let h = m["height"] as? Int,
			let cw = m["chromaWidth"] as? Int, let ch = m["chromaHeight"] as? Int,
			let bps = m["bytesPerSample"] as? Int, let list = m["frames"] as? [[String: Any]]
		else {
			print("couldn't read \(path)/frames.json")
			exit(1)
		}
		manifest = m
		(width, height, chromaWidth, chromaHeight, bytesPerSample) = (w, h, cw, ch, bps)
		fullRange = m["fullRange"] as? Bool ?? false
		bt2020 = m["bt2020"] as? Bool ?? false
		frames = list.compactMap {
			guard let seq = $0["seq"] as? Int else { return nil }
			return CaptureFrame(seq: seq, kind: $0["kind"] as? String ?? "", pair: $0["pair"] as? Int ?? 0,
				file: $0["file"] as? String)
		}
	}

	var lumaFormat: MTLPixelFormat { bytesPerSample == 2 ? .r16Unorm : .r8Unorm }
	var chromaFormat: MTLPixelFormat { bytesPerSample == 2 ? .rg16Unorm : .rg8Unorm }
	var lumaBytes: Int { width * height * bytesPerSample }
	var chromaBytes: Int { chromaWidth * chromaHeight * 2 * bytesPerSample }
}

private typealias Planes = (luma: MTLTexture, chroma: MTLTexture)

private func makeTexture(_ device: MTLDevice, _ format: MTLPixelFormat, _ w: Int, _ h: Int) -> MTLTexture {
	let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
	desc.usage = [.shaderRead, .shaderWrite]
	desc.storageMode = .shared
	return device.makeTexture(descriptor: desc)!
}

private func bytesPerPixel(_ format: MTLPixelFormat) -> Int {
	switch format {
	case .r8Unorm: return 1
	case .rg8Unorm, .r16Unorm: return 2
	case .rg16Unorm: return 4
	default: fatalError("unsupported \(format)")
	}
}

private func load(_ c: Capture, _ device: MTLDevice, _ file: String) -> Planes {
	let raw = try! Data(contentsOf: c.dir.appendingPathComponent(file))
	precondition(raw.count >= c.lumaBytes + c.chromaBytes, "\(file) is too short")
	let luma = makeTexture(device, c.lumaFormat, c.width, c.height)
	let chroma = makeTexture(device, c.chromaFormat, c.chromaWidth, c.chromaHeight)
	raw.withUnsafeBytes { p in
		luma.replace(region: MTLRegionMake2D(0, 0, c.width, c.height), mipmapLevel: 0, withBytes: p.baseAddress!,
			bytesPerRow: c.width * c.bytesPerSample)
		chroma.replace(region: MTLRegionMake2D(0, 0, c.chromaWidth, c.chromaHeight), mipmapLevel: 0,
			withBytes: p.baseAddress! + c.lumaBytes, bytesPerRow: c.chromaWidth * 2 * c.bytesPerSample)
	}
	return (luma, chroma)
}

/// Raw bytes of a (possibly private) texture, tightly packed
private func readRaw(_ device: MTLDevice, _ queue: MTLCommandQueue, _ t: MTLTexture) -> Data {
	let copy = makeTexture(device, t.pixelFormat, t.width, t.height)
	let cb = queue.makeCommandBuffer()!
	let blit = cb.makeBlitCommandEncoder()!
	blit.copy(from: t, to: copy)
	blit.endEncoding()
	cb.commit()
	cb.waitUntilCompleted()
	let row = t.width * bytesPerPixel(t.pixelFormat)
	var out = Data(count: row * t.height)
	out.withUnsafeMutableBytes {
		copy.getBytes($0.baseAddress!, bytesPerRow: row, from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0)
	}
	return out
}

/// Luma as 8-bit values (10-bit samples sit in the top bits of 16)
private func luma8(_ c: Capture, _ raw: Data) -> [UInt8] {
	let n = c.width * c.height
	return raw.withUnsafeBytes { p in
		c.bytesPerSample == 2
			? (0..<n).map { UInt8(p.load(fromByteOffset: $0 * 2, as: UInt16.self) >> 8) }
			: Array(p.prefix(n))
	}
}

/// Pixels with a strong edge nearby: where text, icons and thin lines are
private func detailMask(_ y: [UInt8], _ w: Int, _ h: Int) -> [Bool] {
	var edge = [Bool](repeating: false, count: w * h)
	for row in 1..<(h - 1) {
		for x in 1..<(w - 1) {
			let i = row * w + x
			let gx = abs(Int(y[i + 1]) - Int(y[i - 1])), gy = abs(Int(y[i + w]) - Int(y[i - w]))
			edge[i] = gx + gy > 40
		}
	}
	// Grow by 1 px so a slightly shifted edge still counts
	var mask = edge
	for row in 1..<(h - 1) {
		for x in 1..<(w - 1) where edge[row * w + x] {
			for d in [-w - 1, -w, -w + 1, -1, 1, w - 1, w, w + 1] { mask[row * w + x + d] = true }
		}
	}
	return mask
}

private func dumpVectors(_ v: [Float], _ w: Int, _ h: Int, _ url: URL) {
	var rgba = [UInt8](repeating: 255, count: w * h * 4)
	for i in 0..<(w * h) {
		rgba[i * 4] = UInt8(max(0, min(255, 128 + v[i * 2] * 4)))
		rgba[i * 4 + 1] = UInt8(max(0, min(255, 128 + v[i * 2 + 1] * 4)))
		rgba[i * 4 + 2] = 128
	}
	let image = CGImage(
		width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
		space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
		provider: CGDataProvider(data: Data(rgba) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
	let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
	CGImageDestinationAddImage(dest, image, nil)
	CGImageDestinationFinalize(dest)
}

private func meanAbs(_ a: [UInt8], _ b: [UInt8], _ mask: [Bool]? = nil) -> (mean: Double, psnr: Double) {
	var sum = 0.0, se = 0.0, n = 0
	for i in 0..<a.count where mask?[i] ?? true {
		let d = Double(a[i]) - Double(b[i])
		sum += abs(d)
		se += d * d
		n += 1
	}
	guard n > 0 else { return (0, 99) }
	let mse = se / Double(n)
	return (sum / Double(n), mse == 0 ? 99 : 10 * log10(255 * 255 / mse))
}

func replay(_ path: String, generator: FrameInterpolator, device: MTLDevice, queue: MTLCommandQueue, outDir: URL,
	name: String, from: Int, to: Int)
{
	let c = Capture(path)
	let probeArg: [(Int, Int)]? = arg("--probe").map {
		$0.split(separator: ";").map { p in
			let v = p.split(separator: ",").compactMap { Int($0) }
			return (v[0], v[1])
		}
	}
	let reals = c.frames.filter { $0.kind == "real" && $0.file != nil && $0.seq >= from && $0.seq <= to }
	guard reals.count >= 3 else {
		print("need at least 3 real frames, found \(reals.count)")
		exit(1)
	}
	// The phone's generated frame for a pair sits between that pair's real
	// frame and the one before
	var phoneGenerated: [Int: CaptureFrame] = [:]
	for f in c.frames where f.kind == "generated" && f.file != nil { phoneGenerated[f.pair] = f }
	print("replaying \(reals.count) real frames from \(c.dir.lastPathComponent): \(c.width)x\(c.height), "
		+ "\(c.bytesPerSample == 2 ? "10" : "8")-bit, generator in capture: \(c.manifest["generator"] ?? "?")")

	func run(_ prev: Planes?, _ cur: Planes) -> Data? {
		let cb = queue.makeCommandBuffer()!
		let paired = generator.push(luma: cur.luma, chroma: cur.chroma, bt2020: c.bt2020, fullRange: c.fullRange, into: cb)
		if paired, let prev { generator.interpolate(previous: prev, current: cur, into: cb) }
		cb.commit()
		cb.waitUntilCompleted()
		precondition(cb.status == .completed, "GPU error: \(String(describing: cb.error))")
		guard paired, prev != nil else { return nil }
		return readRaw(device, queue, generator.outLuma!) + readRaw(device, queue, generator.outChroma!)
	}

	// 1. Halfway frames, as the phone made them, into a capture folder
	let out = outDir.appendingPathComponent("replay-\(name)")
	try? FileManager.default.removeItem(at: out)
	try! FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
	var manifest = c.manifest
	var list: [[String: Any]] = []
	var vsPhone: [Double] = []
	generator.reset()
	var prev: Planes?
	for (i, r) in reals.enumerated() {
		let cur = load(c, device, r.file!)
		if let gen = run(prev, cur) {
			let seq = phoneGenerated[r.pair]?.seq ?? r.seq - 1
			let file = String(format: "%06d-generated.yuv", seq)
			try! gen.write(to: out.appendingPathComponent(file))
			list.append(["seq": seq, "kind": "generated", "pair": r.pair, "file": file])
			// `--probe X,Y[;X,Y...]`: the motion map's half motion at these
			// luma pixels, for each generated frame
			if let probes = probeArg, let fg = generator as? FrameGenerator, let map = fg.motion {
				let v = readVectors(map)
				let line = probes.map { (x, y) -> String in
					let i = ((y / 4) * map.width + x / 4) * 2
					return String(format: "(%d,%d) %.2f,%.2f", x, y, v[i], v[i + 1])
				}
				var g = [Float](repeating: 0, count: 4)
				if let gt = fg.dominantMotion {
					let shared = makeTexture(device, .rgba32Float, 1, 1)
					let cb = queue.makeCommandBuffer()!
					let blit = cb.makeBlitCommandEncoder()!
					blit.copy(from: gt, to: shared)
					blit.endEncoding()
					cb.commit()
					cb.waitUntilCompleted()
					g.withUnsafeMutableBytes {
						shared.getBytes($0.baseAddress!, bytesPerRow: 16, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
					}
				}
				print("  pair \(r.pair): "
					+ String(format: "dominant %.2f,%.2f (%.0f%%) trust %.2f  ", g[0], g[1], g[2] * 100, g[3])
					+ line.joined(separator: "  "))
			}
			// `--dump PAIR`: each stage's motion as a PNG (red = x, green = y,
			// grey = none, 4 levels per px of half motion)
			if Int(arg("--dump") ?? "") == r.pair, let fg = generator as? FrameGenerator {
				for (name, t) in [("patch", fg.rawPatchMotion!), ("median", fg.patchMotion!),
					("map", fg.motion!)]
				{
					dumpVectors(readVectors(t), t.width, t.height, out.appendingPathComponent("motion-\(r.pair)-\(name).png"))
				}
			}
			if let phone = phoneGenerated[r.pair], let raw = try? Data(contentsOf: c.dir.appendingPathComponent(phone.file!)) {
				vsPhone.append(meanAbs(luma8(c, gen), luma8(c, raw)).mean)
			}
		}
		try! FileManager.default.copyItem(
			at: c.dir.appendingPathComponent(r.file!), to: out.appendingPathComponent(r.file!))
		list.append(["seq": r.seq, "kind": "real", "pair": r.pair, "file": r.file!])
		prev = cur
		if i % 20 == 0 { print("  \(i)/\(reals.count)") }
	}
	manifest["frames"] = list
	manifest["generator"] = "\(manifest["generator"] ?? "?") (replayed on \(device.name))"
	try! JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
		.write(to: out.appendingPathComponent("frames.json"))
	if !vsPhone.isEmpty {
		print(String(format: "vs the phone's generated frames: mean luma diff %.2f (max of %d frames %.2f)",
			vsPhone.reduce(0, +) / Double(vsPhone.count), vsPhone.count, vsPhone.max()!))
	}
	print("wrote \(out.path): scripts/fgcapture/run.sh \(out.path) --crop X,Y,W,H")

	// 2. Leave-one-out: every other real frame as the pair, the one between as
	// the answer. Two runs (even and odd starting frame) so each real frame
	// in the middle is scored once, each a continuous sequence like a stream.
	var all: [(mean: Double, psnr: Double)] = [], detail: [(mean: Double, psnr: Double)] = []
	var shimmer: [Double] = []
	for start in 0..<2 {
		generator.reset()
		var prev: Planes?
		var lastErr: [Int]?
		var k = start
		while k < reals.count {
			let cur = load(c, device, reals[k].file!)
			if let gen = run(prev, cur) {
				let truthRaw = try! Data(contentsOf: c.dir.appendingPathComponent(reals[k - 1].file!))
				let truth = luma8(c, truthRaw), got = luma8(c, gen)
				all.append(meanAbs(got, truth))
				detail.append(meanAbs(got, truth, detailMask(truth, c.width, c.height)))
				// Shimmer on static parts can't be told apart here, so this is
				// only the error's change between consecutive results
				let err = zip(got, truth).map { Int($0) - Int($1) }
				if let lastErr {
					shimmer.append(Double(zip(err, lastErr).reduce(0) { $0 + abs($1.0 - $1.1) }) / Double(err.count))
				}
				lastErr = err
			}
			prev = cur
			k += 2
		}
	}
	func avg(_ v: [Double]) -> Double { v.reduce(0, +) / Double(max(v.count, 1)) }
	print(String(format: "leave-one-out over %d frames: all pixels mean abs %.2f, PSNR %.2f dB (min %.2f)",
		all.count, avg(all.map(\.mean)), avg(all.map(\.psnr)), all.map(\.psnr).min() ?? 0))
	print(String(format: "  detail pixels: mean abs %.2f, PSNR %.2f dB (min %.2f); error change between frames %.3f",
		avg(detail.map(\.mean)), avg(detail.map(\.psnr)), detail.map(\.psnr).min() ?? 0, avg(shimmer)))
}
