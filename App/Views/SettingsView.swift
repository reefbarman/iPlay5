import SwiftUI

/// Stream settings, shared by the main settings sheet and the in-stream menu.
struct StreamSettingsForm: View {
	@Binding var settings: StreamSettings
	/// Set when the video and network settings shown are this console's own
	var customConsoleName: String?
	/// Overrides the bitrate slider's label, e.g. while streaming on a network with a learned bitrate
	var bitrateTitle: String?

	@Environment(BitrateMemory.self) private var bitrateMemory

	private var upscalingSelection: Binding<UpscalingMode> {
		Binding(
			get: { settings.upscaling.usesMetalFX && !MetalRenderer.supportsMetalFX ? .sharp : settings.upscaling },
			set: { settings.upscaling = $0 })
	}

	private var opacityPercent: Int { Int((settings.controlsOpacity * 100).rounded()) }

	var body: some View {
		VideoSettingsSection(settings: $settings, customConsoleName: customConsoleName, bitrateTitle: bitrateTitle)

		Section {
			Toggle("Auto bitrate", isOn: $settings.autoBitrate)
			if settings.autoBitrate && !bitrateMemory.entries.isEmpty {
				Button("Forget learned bitrates", role: .destructive) { bitrateMemory.forgetAll() }
			}
		} footer: {
			Text("Remembers the bitrate that works for each console on each Wi-Fi network, so you don't have to keep tuning it. A new network starts at the starting bitrate above. After a few minutes of smooth play it goes up about a fifth next time (up to 100 Mbps, or your starting bitrate if that's higher), and after a session that drops video it comes down a quarter. It never changes mid-game. Moving the bitrate slider while you play, or applying an Optimise connection suggestion, sets it for that network.")
		}

		Section {
			Picker("Picture", selection: $settings.displayMode) {
				ForEach(DisplayMode.allCases) { Text($0.label).tag($0) }
			}
			Picker("Upscaling", selection: upscalingSelection) {
				ForEach(UpscalingMode.allCases.filter { !$0.usesMetalFX || MetalRenderer.supportsMetalFX }) {
					Text($0.label).tag($0)
				}
			}
			if UIScreen.main.maximumFramesPerSecond > 60 {
				Toggle("120 Hz screen", isOn: $settings.highRefreshDisplay)
			}
			Toggle("Frame generation (experimental)", isOn: $settings.frameGeneration)
			Picker("Stats", selection: $settings.statsMode) {
				ForEach(StatsMode.allCases) { Text($0.label).tag($0) }
			}
		} header: {
			Text("Display")
		} footer: {
			Text("Fit shows the whole picture, with black bars where the screen is a different shape to 16:9. Zoom fills the screen and crops the overflow. 120 Hz screen gets each frame on screen sooner, for a little more battery. Frame generation makes an extra frame between each pair the PS5 sends, so 30 fps looks like 60 and 60 like 120, for half a frame of extra delay. 60 fps needs the 120 Hz screen. The FG button in the bottom-right corner of the stream turns it on and off. Stats sit in the black bar above the picture: Simple shows the essentials, Advanced shows everything.")
			if MetalRenderer.supportsMetalFX {
				Text("MetalFX Spatial enlarges the picture to the screen's resolution. MetalFX 4K enlarges it to 3840×2160 and then scales it down to the screen, which can look smoother but uses more GPU and battery.")
			}
		}

		Section {
			Toggle("Rumble", isOn: $settings.rumble)
			Picker("Phone haptics", selection: $settings.phoneHaptics) {
				ForEach(PhoneHaptics.allCases) { Text($0.label).tag($0) }
			}
			.disabled(!settings.rumble)
			Toggle("Phone gyro for motion controls", isOn: $settings.phoneMotion)
			Toggle("Select button is touchpad click", isOn: $settings.selectIsTouchpad)
			NavigationLink { ControlsGuideView() } label: {
				Label("Controls Guide", systemImage: "gamecontroller")
			}
		} header: {
			Text("Controller")
		} footer: {
			Text("Rumble turns all vibration on or off. Phone haptics sets how strongly the phone itself vibrates, which it does with virtual controls or a controller that has no motors (like a Backbone or GameSir G8+). Phone gyro works without a controller or with one that has no motion sensors, like a GameSir G8+. Hold Select + Start for a second during a stream to open the menu.")
		}

		Section {
			Picker("Show", selection: $settings.virtualControls) {
				ForEach(VirtualControlsMode.allCases) { Text($0.label).tag($0) }
			}
			if settings.virtualControls != .never {
				Picker("Size", selection: $settings.controlsSize) {
					ForEach(ControlsSize.allCases) { Text($0.label).tag($0) }
				}
				VStack(alignment: .leading) {
					HStack {
						Text("Opacity")
						Spacer()
						Text("\(opacityPercent)%").foregroundStyle(.secondary).monospacedDigit()
					}
					Slider(value: $settings.controlsOpacity, in: 0.2...1, step: 0.05)
				}
				Toggle("Fixed sticks", isOn: $settings.fixedSticks)
			}
		} header: {
			Text("Virtual controls")
		} footer: {
			Text("Auto shows virtual controls when no supported controller is connected. Sticks normally start wherever your thumb lands in the lower half. Fixed sticks stay in one spot on each side instead, and a touch near one moves it straight away.")
		}

		NetworkSettingsSections(settings: $settings, customConsoleName: customConsoleName)

		Section {
			Toggle("Frame capture button", isOn: $settings.frameCapture)
		} header: {
			Text("Debug")
		} footer: {
			Text("Adds a button at the bottom left of the stream that saves the last couple of seconds of frames, real and generated, to Files › On My iPhone › iPlay5 › Frame captures. Uses up to about 800 MB of memory while on.")
		}
	}
}

/// Resolution, frame rate, bitrate, codec and HDR. A console can have its own.
struct VideoSettingsSection: View {
	@Binding var settings: StreamSettings
	var customConsoleName: String?
	var bitrateTitle: String?

	var body: some View {
		Section {
			Picker("Resolution", selection: $settings.resolution) {
				ForEach(StreamResolution.allCases) { Text($0.label).tag($0) }
			}
			Picker("Frame rate", selection: $settings.fps) {
				Text("60 fps").tag(60)
				Text("30 fps").tag(30)
			}
			VStack(alignment: .leading) {
				HStack {
					Text(bitrateTitle ?? (settings.autoBitrate ? "Starting bitrate" : "Bitrate"))
					Spacer()
					Text("\(settings.bitrateMbps) Mbps").foregroundStyle(.secondary).monospacedDigit()
				}
				Slider(value: Binding(get: { Double(settings.bitrateMbps) }, set: { settings.bitrateMbps = Int($0) }), in: 5...200, step: 5)
			}
			Picker("Codec", selection: $settings.codec) {
				ForEach(VideoCodecChoice.allCases) { Text($0.label).tag($0) }
			}
			.disabled(settings.hdr)
			Toggle("HDR", isOn: $settings.hdr)
		} header: {
			Text(customConsoleName.map { "Video for \($0)" } ?? "Video")
		} footer: {
			Text("PS5 Remote Play tops out at 1080p60. The PS5 may cap the bitrate below what you ask for, so watch the stats overlay. Above 100 Mbps needs a strong connection (ideally the PS5 on Ethernet and 5 GHz or 6 GHz Wi-Fi) or you may see stutter. HDR needs H.265 and HDR turned on in the PS5's video output settings. Changing these reconnects the stream.")
			if customConsoleName == nil {
				Text("To give one console its own video and network settings, swipe left on it in the console list and tap Settings.")
			}
		}
	}
}

/// Network smoothing and Takion v20. A console can have its own.
struct NetworkSettingsSections: View {
	@Binding var settings: StreamSettings
	var customConsoleName: String?

	var body: some View {
		Section {
			Toggle("Smooth network hiccups", isOn: $settings.networkSmoothing)
		} header: {
			Text(customConsoleName.map { "Network for \($0)" } ?? "Network")
		} footer: {
			Text("For Wi-Fi that stutters. Waits a little longer for late video, keeps the picture moving (briefly smeared) instead of freezing when a frame is lost, and evens out uneven frames by holding one or two back. That adds up to about 17 ms per frame held, only while the network is acting up, and goes back to normal once it's calm. The stats overlay shows what it's doing. Changing this reconnects the stream.")
		}

		Section {
			Toggle("Takion v20 protocol (experimental)", isOn: $settings.takionV20)
		} footer: {
			Text("Offers the PS5 the newer stream protocol that recent official apps use. The PS5 decides; if it doesn't answer, the stream stays on the usual protocol. There's no measured latency gain yet, so compare with it off. The stats overlay shows which one is in use. Changing this reconnects the stream.")
		}
	}
}

/// A console's own video and network settings, for when it's on a different
/// connection to the others (e.g. one on Ethernet, one on Wi-Fi)
struct ConsoleSettingsView: View {
	let consoleID: UUID

	@Environment(ConsoleStore.self) private var consoles
	@Environment(SettingsStore.self) private var store
	@Environment(\.dismiss) private var dismiss

	private var console: Console? { consoles.consoles.first { $0.id == consoleID } }

	private var custom: Binding<Bool> {
		Binding(
			get: { console?.customSettings != nil },
			set: { on in
				guard var console else { return }
				// Start from the shared settings, so turning it on changes nothing until you edit
				console.customSettings = on ? store.settings.connection : nil
				consoles.update(console)
			})
	}

	/// The shared settings with this console's video and network settings on top.
	/// Edits only keep the video and network part.
	private var settings: Binding<StreamSettings> {
		Binding(
			get: { store.settings.applying(console?.customSettings) },
			set: { new in
				guard var console, console.customSettings != nil else { return }
				console.customSettings = new.connection
				consoles.update(console)
			})
	}

	var body: some View {
		NavigationStack {
			Form {
				if let console {
					Section {
						Toggle("Custom settings", isOn: custom)
					} footer: {
						Text("Give \(console.name) its own video and network settings, for example when it's on Ethernet and your other console is on Wi-Fi. Display and controller settings are always shared. While you play \(console.name), changes to video and network settings in the stream menu are saved here.")
					}
					if console.customSettings != nil {
						VideoSettingsSection(settings: settings, customConsoleName: console.name)
						NetworkSettingsSections(settings: settings, customConsoleName: console.name)
					}
				}
			}
			.navigationTitle(console?.name ?? "Console")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
			}
		}
	}
}

struct SettingsView: View {
	@Environment(SettingsStore.self) private var store
	@Environment(ConsoleStore.self) private var consoles
	@Environment(\.dismiss) private var dismiss
	@State private var isPreparingDiagnostics = false
	@State private var diagnosticsShare: DiagnosticsShare?
	@State private var showDiagnosticsError = false

	var body: some View {
		@Bindable var store = store
		NavigationStack {
			Form {
				StreamSettingsForm(settings: $store.settings)

				Section {
					Button {
						isPreparingDiagnostics = true
					} label: {
						if isPreparingDiagnostics {
							ProgressView("Preparing diagnostics…")
						} else {
							Label("Share diagnostics", systemImage: "ladybug")
						}
					}
					.disabled(isPreparingDiagnostics || diagnosticsShare != nil)
					Link(destination: URL(string: "https://github.com/reefbarman/iPlay5/issues/new")!) {
						Label("Report a problem on GitHub", systemImage: "exclamationmark.bubble")
					}
				} header: {
					Text("Help")
				} footer: {
					Text("The report has your phone model, screen details, settings and the app's logs since it was opened. IP addresses, keys, account IDs and console names are removed. Share it before closing the app, so the logs still cover the problem.")
				}
			}
			.navigationTitle("Settings")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
			}
			.task(id: isPreparingDiagnostics) {
				guard isPreparingDiagnostics else { return }
				await prepareDiagnostics()
			}
			.sheet(item: $diagnosticsShare) { share in
				share
			}
			.alert("Couldn't prepare diagnostics", isPresented: $showDiagnosticsError) {
				Button("OK", role: .cancel) {}
			} message: {
				Text("Try sharing diagnostics again.")
			}
		}
	}

	private func prepareDiagnostics() async {
		let report = DiagnosticsReport(consoleNames: consoles.consoles.map(\.name), settings: store.settings)
		do {
			let url = try await report.writeFile()
			guard !Task.isCancelled else { return }
			diagnosticsShare = DiagnosticsShare(url: url)
		} catch {
			guard !Task.isCancelled else { return }
			showDiagnosticsError = true
		}
		isPreparingDiagnostics = false
	}
}

private struct DiagnosticsShare: UIViewControllerRepresentable, Identifiable {
	let url: URL
	var id: URL { url }

	func makeUIViewController(context: Context) -> UIActivityViewController {
		UIActivityViewController(activityItems: [url], applicationActivities: nil)
	}

	func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
