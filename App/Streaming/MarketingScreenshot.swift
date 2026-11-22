import ImageIO
import UIKit
import UniformTypeIdentifiers

@MainActor
enum MarketingScreenshot {
	enum CaptureError: LocalizedError {
		case streamUnavailable, noFrame, renderFailed, encodingFailed

		var errorDescription: String? {
			switch self {
			case .streamUnavailable: "Resume the stream and try again."
			case .noFrame: "No video frame is ready. Try again while the stream is playing."
			case .renderFailed: "Couldn't render the stream and controls."
			case .encodingFailed: "The screenshot couldn't be converted to PNG."
			}
		}
	}

	static func save(renderer: MetalRenderer) async throws -> String {
		guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
			.first(where: { $0.activationState == .foregroundActive })?.keyWindow,
			let video = streamView(in: window, renderer: renderer)
		else { throw CaptureError.streamUnavailable }

		let bounds = window.bounds
		let scale = window.screen.nativeScale
		let frame = try await renderer.renderScreenshotFrame()
		try Task.checkCancellation()
		guard video.window === window, window.bounds == bounds, window.screen.nativeScale == scale,
			window.windowScene?.activationState == .foregroundActive
		else { throw CaptureError.streamUnavailable }

		let format = UIGraphicsImageRendererFormat()
		format.scale = scale
		format.opaque = true
		format.preferredRange = .standard
		let composite = try video.withScreenshotVideo(frame) {
			var drewHierarchy = false
			let snapshot = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
				drewHierarchy = window.drawHierarchy(in: bounds, afterScreenUpdates: true)
			}
			guard drewHierarchy, let image = snapshot.cgImage else { throw CaptureError.renderFailed }
			return image
		}
		return try await writePNG(composite)
	}

	private static func streamView(in view: UIView, renderer: MetalRenderer) -> StreamMetalView? {
		if let stream = view as? StreamMetalView, stream.renderer === renderer { return stream }
		for child in view.subviews {
			if let stream = streamView(in: child, renderer: renderer) { return stream }
		}
		return nil
	}

	nonisolated private static func writePNG(_ image: CGImage) async throws -> String {
		try Task.checkCancellation()
		let png = NSMutableData()
		guard let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil)
		else { throw CaptureError.encodingFailed }
		CGImageDestinationAddImage(destination, image, nil)
		guard CGImageDestinationFinalize(destination) else { throw CaptureError.encodingFailed }

		let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
			appropriateFor: nil, create: true)
		let filename = "Screenshot-\(UUID().uuidString.prefix(8)).png"
		try png.write(to: documents.appendingPathComponent(filename), options: .atomic)
		return filename
	}
}
