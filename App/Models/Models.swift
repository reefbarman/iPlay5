import Foundation
import Observation

/// A PlayStation that has been registered (linked) with this phone.
struct Console: Codable, Identifiable, Hashable {
	var id = UUID()
	var name: String
	var host: String
	var ps5: Bool
	/// rp_regist_key: 16 bytes (ASCII hex, zero padded)
	var registKey: Data
	/// rp_key ("morning"): 16 bytes
	var rpKey: Data
	var mac: Data
}

@Observable
final class ConsoleStore {
	private(set) var consoles: [Console] = []

	@ObservationIgnored private let url: URL = {
		let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		return dir.appendingPathComponent("consoles.json")
	}()

	init() {
		if let data = try? Data(contentsOf: url),
			let decoded = try? JSONDecoder().decode([Console].self, from: data)
		{
			consoles = decoded
		}
	}

	func add(_ console: Console) {
		// Re-registering the same console replaces the old keys
		consoles.removeAll { $0.mac == console.mac && !console.mac.isEmpty }
		consoles.append(console)
		save()
	}

	func update(_ console: Console) {
		guard let index = consoles.firstIndex(where: { $0.id == console.id }) else { return }
		consoles[index] = console
		save()
	}

	func remove(_ console: Console) {
		consoles.removeAll { $0.id == console.id }
		save()
	}

	private func save() {
		do {
			let data = try JSONEncoder().encode(consoles)
			try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
		} catch {
			log.error("Saving consoles failed: \(error.localizedDescription, privacy: .public)")
		}
	}
}

// MARK: - Stream settings

enum StreamResolution: Int, Codable, CaseIterable, Identifiable {
	case p720 = 720
	case p1080 = 1080

	var id: Int { rawValue }
	var label: String { "\(rawValue)p" }
	var size: (width: UInt32, height: UInt32) {
		switch self {
		case .p720: (1280, 720)
		case .p1080: (1920, 1080)
		}
	}
}

enum VideoCodecChoice: String, Codable, CaseIterable, Identifiable {
	case h265
	case h264

	var id: String { rawValue }
	var label: String { self == .h265 ? "H.265 (HEVC)" : "H.264" }
}

enum DisplayMode: String, Codable, CaseIterable, Identifiable {
	/// Whole picture visible, black bars where the screen isn't 16:9
	case fit
	/// Fill the screen, cropping whatever overflows
	case zoom

	var id: String { rawValue }
	var label: String { self == .fit ? "Fit" : "Zoom to fill" }
}


enum VirtualControlsMode: String, Codable, CaseIterable, Identifiable {
	case auto, always, never

	var id: Self { self }
	var label: String {
		switch self {
		case .auto: "Auto"
		case .always: "Always show"
		case .never: "Never show"
		}
	}
}

enum UpscalingMode: String, Codable, CaseIterable, Identifiable {
	case bilinear, sharp, metalFX

	var id: Self { self }
	var label: String {
		switch self {
		case .bilinear: "Bilinear"
		case .sharp: "Sharp"
		case .metalFX: "MetalFX Spatial"
		}
	}
}

struct StreamSettings: Codable, Equatable {
	var resolution: StreamResolution = .p1080
	var fps: Int = 60
	var bitrateMbps: Int = 30
	var codec: VideoCodecChoice = .h265
	var hdr: Bool = false
	var displayMode: DisplayMode = .fit
	var upscaling: UpscalingMode = .sharp
	var showStats: Bool = false
	/// Phone gyro for controllers without motion sensors (e.g. GameSir G8+)
	var phoneMotion: Bool = true
	var rumble: Bool = true
	/// Use the controller's Select/View button as the DualSense touchpad click
	var selectIsTouchpad: Bool = false
	var virtualControls: VirtualControlsMode = .auto
	/// Keep a ProMotion screen at 120 Hz while streaming, so frames wait less for the next refresh
	var highRefreshDisplay: Bool = true
	/// Experimental: make an in-between frame for each pair of real ones (FrameGen.metal)
	var frameGeneration: Bool = false
	/// Debug: a button on the stream that saves the last few seconds of frames
	var frameCapture: Bool = false
	/// Experimental: offer the PS5 the newer Takion v20 stream protocol. The console picks;
	/// it stays on v12 if it doesn't answer. Off keeps the stock chiaki-ng v12 path.
	var takionV20: Bool = false
	/// Optional: ride out network hitches at the cost of a little delay while they happen.
	/// Waits longer for late video packets, keeps the picture moving (briefly smeared)
	/// instead of freezing after a lost frame, and holds back a frame or two to even out
	/// uneven arrival (FramePacer). ChiakiKit/patches/0002-network-smoothing.patch.
	var networkSmoothing: Bool = false

	/// HDR needs HEVC
	var effectiveCodec: VideoCodecChoice { hdr ? .h265 : codec }

	init() {}

	private enum LegacyKeys: String, CodingKey { case frameGenMode, sharpUpscaling }

	/// Missing keys keep their defaults, so adding a setting doesn't reset the others
	init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		let d = StreamSettings()
		resolution = try c.decodeIfPresent(StreamResolution.self, forKey: .resolution) ?? d.resolution
		fps = try c.decodeIfPresent(Int.self, forKey: .fps) ?? d.fps
		bitrateMbps = try c.decodeIfPresent(Int.self, forKey: .bitrateMbps) ?? d.bitrateMbps
		codec = try c.decodeIfPresent(VideoCodecChoice.self, forKey: .codec) ?? d.codec
		hdr = try c.decodeIfPresent(Bool.self, forKey: .hdr) ?? d.hdr
		displayMode = try c.decodeIfPresent(DisplayMode.self, forKey: .displayMode) ?? d.displayMode
		let legacy = try decoder.container(keyedBy: LegacyKeys.self)
		if let mode = try? c.decodeIfPresent(UpscalingMode.self, forKey: .upscaling) {
			upscaling = mode
		} else if let sharp = try? legacy.decodeIfPresent(Bool.self, forKey: .sharpUpscaling) {
			upscaling = sharp ? .sharp : .bilinear
		}
		showStats = try c.decodeIfPresent(Bool.self, forKey: .showStats) ?? d.showStats
		phoneMotion = try c.decodeIfPresent(Bool.self, forKey: .phoneMotion) ?? d.phoneMotion
		rumble = try c.decodeIfPresent(Bool.self, forKey: .rumble) ?? d.rumble
		selectIsTouchpad = try c.decodeIfPresent(Bool.self, forKey: .selectIsTouchpad) ?? d.selectIsTouchpad
		virtualControls = (try? c.decodeIfPresent(VirtualControlsMode.self, forKey: .virtualControls)) ?? d.virtualControls
		highRefreshDisplay = try c.decodeIfPresent(Bool.self, forKey: .highRefreshDisplay) ?? d.highRefreshDisplay
		if let on = try c.decodeIfPresent(Bool.self, forKey: .frameGeneration) {
			frameGeneration = on
		} else if let mode = try? legacy.decodeIfPresent(String.self, forKey: .frameGenMode) {
			frameGeneration = mode != "off"
		}
		frameCapture = try c.decodeIfPresent(Bool.self, forKey: .frameCapture) ?? d.frameCapture
		takionV20 = try c.decodeIfPresent(Bool.self, forKey: .takionV20) ?? d.takionV20
		networkSmoothing = try c.decodeIfPresent(Bool.self, forKey: .networkSmoothing) ?? d.networkSmoothing
	}
}

@Observable
final class SettingsStore {
	var settings: StreamSettings {
		didSet { save() }
	}

	@ObservationIgnored private let key = "streamSettings"

	init() {
		if let data = UserDefaults.standard.data(forKey: key),
			let decoded = try? JSONDecoder().decode(StreamSettings.self, from: data)
		{
			settings = decoded
		} else {
			settings = StreamSettings()
		}
	}

	private func save() {
		if let data = try? JSONEncoder().encode(settings) {
			UserDefaults.standard.set(data, forKey: key)
		}
	}
}
