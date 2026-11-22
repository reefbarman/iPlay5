import SwiftUI

/// Stream settings, shared by the main settings sheet and the in-stream menu.
struct StreamSettingsForm: View {
	@Binding var settings: StreamSettings

	private var upscalingSelection: Binding<UpscalingMode> {
		Binding(
			get: { settings.upscaling.usesMetalFX && !MetalRenderer.supportsMetalFX ? .sharp : settings.upscaling },
			set: { settings.upscaling = $0 })
	}

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
					Text("Bitrate")
					Spacer()
					Text("\(settings.bitrateMbps) Mbps").foregroundStyle(.secondary).monospacedDigit()
				}
				Slider(value: Binding(get: { Double(settings.bitrateMbps) }, set: { settings.bitrateMbps = Int($0) }), in: 5...100, step: 5)
			}
			Picker("Codec", selection: $settings.codec) {
				ForEach(VideoCodecChoice.allCases) { Text($0.label).tag($0) }
			}
			.disabled(settings.hdr)
			Toggle("HDR", isOn: $settings.hdr)
		} header: {
			Text("Video")
		} footer: {
			Text("PS5 Remote Play tops out at 1080p60. The PS5 may cap the bitrate below what you ask for, so watch the stats overlay. HDR needs H.265 and HDR turned on in the PS5's video output settings. Changing these reconnects the stream.")
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
			Toggle("Show stats", isOn: $settings.showStats)
		} header: {
			Text("Display")
		} footer: {
			Text("Fit shows the whole picture, with black bars where the screen is a different shape to 16:9. Zoom fills the screen and crops the overflow. 120 Hz screen gets each frame on screen sooner, for a little more battery. Frame generation makes an extra frame between each pair the PS5 sends, so 30 fps looks like 60 and 60 like 120, for half a frame of extra delay. 60 fps needs the 120 Hz screen. The FG button in the bottom-right corner of the stream turns it on and off.")
			if MetalRenderer.supportsMetalFX {
				Text("MetalFX Spatial enlarges the picture to the screen's resolution. MetalFX 4K enlarges it to 3840×2160 and then scales it down to the screen, which can look smoother but uses more GPU and battery.")
			}
		}

		Section {
			Picker("Virtual controls", selection: $settings.virtualControls) {
				ForEach(VirtualControlsMode.allCases) { Text($0.label).tag($0) }
			}
			Toggle("Rumble", isOn: $settings.rumble)
			Toggle("Phone gyro for motion controls", isOn: $settings.phoneMotion)
			Toggle("Select button is touchpad click", isOn: $settings.selectIsTouchpad)
		} header: {
			Text("Controller")
		} footer: {
			Text("Auto shows virtual controls when no supported controller is connected. Phone gyro works without a controller or with one that has no motion sensors, like a GameSir G8+. Hold Select + Start for a second during a stream to open the menu.")
		}

		Section {
			Toggle("Smooth network hiccups", isOn: $settings.networkSmoothing)
		} header: {
			Text("Network")
		} footer: {
			Text("For Wi-Fi that stutters. Waits a little longer for late video, keeps the picture moving (briefly smeared) instead of freezing when a frame is lost, and evens out uneven frames by holding one or two back. That adds up to about 17 ms per frame held, only while the network is acting up, and goes back to normal once it's calm. The stats overlay shows what it's doing. Changing this reconnects the stream.")
		}

		Section {
			Toggle("Takion v20 protocol (experimental)", isOn: $settings.takionV20)
		} footer: {
			Text("Offers the PS5 the newer stream protocol that recent official apps use. The PS5 decides; if it doesn't answer, the stream stays on the usual protocol. There's no measured latency gain yet, so compare with it off. The stats overlay shows which one is in use. Changing this reconnects the stream.")
		}

		Section {
			Toggle("Frame capture button", isOn: $settings.frameCapture)
		} header: {
			Text("Debug")
		} footer: {
			Text("Adds a button at the bottom left of the stream that saves the last couple of seconds of frames, real and generated, to Files › On My iPhone › iPlay5 › Frame captures. Uses up to about 800 MB of memory while on.")
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
				Section {
					NavigationLink { ControlsGuideView() } label: {
						Label("Controls Guide", systemImage: "gamecontroller")
					}
				}
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
