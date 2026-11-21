// fgcapture: turns a frame capture saved on the phone (the stream's debug
// capture button) into PNGs, and prints its timeline.
//
//   scripts/fgcapture/run.sh CAPTURE_DIR [--out DIR] [--crop X,Y,W,H] [--from SEQ] [--to SEQ]
//
// CAPTURE_DIR is a folder from Files › iPlay5 › Frame captures (copy it over
// with Finder or AirDrop). PNGs go to CAPTURE_DIR/png unless --out is given,
// named like the raw files (000123-real.png, 000124-generated.png). --crop
// cuts out a region in luma pixels, for a close look at small detail.
// HDR captures are shown as their PQ code values, without tone mapping.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
func arg(_ name: String) -> String? {
	guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
	return args[i + 1]
}
guard args.count > 1, !args[1].hasPrefix("--") else {
	print("usage: run.sh CAPTURE_DIR [--out DIR] [--crop X,Y,W,H] [--from SEQ] [--to SEQ]")
	exit(1)
}
let dir = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: arg("--out") ?? dir.appendingPathComponent("png").path)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

guard let data = try? Data(contentsOf: dir.appendingPathComponent("frames.json")),
	let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
	let width = manifest["width"] as? Int, let height = manifest["height"] as? Int,
	let cw = manifest["chromaWidth"] as? Int, let ch = manifest["chromaHeight"] as? Int,
	let bps = manifest["bytesPerSample"] as? Int, let frames = manifest["frames"] as? [[String: Any]]
else {
	print("couldn't read \(dir.path)/frames.json")
	exit(1)
}
let fullRange = manifest["fullRange"] as? Bool ?? false
let bt2020 = manifest["bt2020"] as? Bool ?? false

var crop = (x: 0, y: 0, w: width, h: height)
if let c = arg("--crop") {
	let v = c.split(separator: ",").compactMap { Int($0) }
	guard v.count == 4 else {
		print("--crop needs X,Y,W,H")
		exit(1)
	}
	crop = (max(0, v[0]), max(0, v[1]), min(v[2], width - max(0, v[0])), min(v[3], height - max(0, v[1])))
}
let from = Int(arg("--from") ?? "") ?? Int.min
let to = Int(arg("--to") ?? "") ?? Int.max

print("\(width)x\(height), \(bps == 2 ? "10-bit" : "8-bit") \(fullRange ? "full" : "video") range, "
	+ "\(bt2020 ? "BT.2020" : "BT.709"), generator: \(manifest["generator"] ?? "?"), "
	+ "stream \(manifest["streamFps"] ?? "?") fps")

/// 8-bit sample `i` of a plane (10-bit samples sit in the top bits of 16)
func sample(_ p: UnsafeRawBufferPointer, _ i: Int) -> Float {
	bps == 2 ? Float(p.load(fromByteOffset: i * 2, as: UInt16.self) >> 8) : Float(p[i])
}

func png(_ raw: Data, _ name: String) throws {
	var rgba = [UInt8](repeating: 255, count: crop.w * crop.h * 4)
	let (kr, kb): (Float, Float) = bt2020 ? (0.2627, 0.0593) : (0.2126, 0.0722)
	let kg = 1 - kr - kb
	raw.withUnsafeBytes { all in
		let luma = UnsafeRawBufferPointer(rebasing: all[0..<(width * height * bps)])
		let chroma = UnsafeRawBufferPointer(rebasing: all[(width * height * bps)...])
		for y in 0..<crop.h {
			let sy = y + crop.y
			let cy = min(sy * ch / height, ch - 1)
			for x in 0..<crop.w {
				let sx = x + crop.x
				let cx = min(sx * cw / width, cw - 1)
				var l = sample(luma, sy * width + sx) / 255
				var cb = sample(chroma, (cy * cw + cx) * 2) / 255 - 0.5
				var cr = sample(chroma, (cy * cw + cx) * 2 + 1) / 255 - 0.5
				if !fullRange {
					l = (l - 16.0 / 255) * 255 / 219
					cb *= 255.0 / 224
					cr *= 255.0 / 224
				}
				let r = l + 2 * (1 - kr) * cr
				let b = l + 2 * (1 - kb) * cb
				let g = (l - kr * r - kb * b) / kg
				let o = (y * crop.w + x) * 4
				rgba[o] = UInt8(max(0, min(255, r * 255 + 0.5)))
				rgba[o + 1] = UInt8(max(0, min(255, g * 255 + 0.5)))
				rgba[o + 2] = UInt8(max(0, min(255, b * 255 + 0.5)))
			}
		}
	}
	let provider = CGDataProvider(data: Data(rgba) as CFData)!
	let image = CGImage(
		width: crop.w, height: crop.h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: crop.w * 4,
		space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
		provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
	let url = outDir.appendingPathComponent(name)
	guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
		throw CocoaError(.fileWriteUnknown)
	}
	CGImageDestinationAddImage(dest, image, nil)
	guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
}

// Timeline: what was encoded and when it reached the screen, with the gap
// since the previous frame on screen
print("seq     kind       pair  encoded ms  shown ms   gap ms  image")
var lastShown: Double?
var written = 0
for f in frames {
	guard let seq = f["seq"] as? Int, seq >= from, seq <= to else { continue }
	let kind = f["kind"] as? String ?? "?"
	let encoded = f["encodedMs"] as? Double ?? 0
	let shown = f["presentedMs"] as? Double
	var gap = ""
	if let shown {
		if let lastShown { gap = String(format: "%.1f", shown - lastShown) }
		lastShown = shown
	}
	var image = "-"
	if let file = f["file"] as? String, let raw = try? Data(contentsOf: dir.appendingPathComponent(file)) {
		let name = (file as NSString).deletingPathExtension + ".png"
		try png(raw, name)
		image = name
		written += 1
	}
	func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }
	func lpad(_ s: String, _ n: Int) -> String { s.count >= n ? s : String(repeating: " ", count: n - s.count) + s }
	print(pad(String(seq), 7) + " " + pad(kind, 10) + " " + pad(String(f["pair"] as? Int ?? 0), 5)
		+ lpad(String(format: "%.1f", encoded), 11) + "  " + lpad(shown.map { String(format: "%.1f", $0) } ?? "not shown", 9)
		+ "  " + lpad(gap, 7) + "  " + image)
}
print("\(written) images in \(outDir.path)")
